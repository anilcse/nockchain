use std::str::FromStr;
use std::time::Duration;

use kernels::miner::KERNEL;
use nockapp::kernel::checkpoint::JamPaths;
use nockapp::kernel::form::Kernel;
use nockapp::nockapp::driver::{IODriverFn, NockAppHandle, PokeResult};
use nockapp::nockapp::wire::Wire;
use nockapp::nockapp::NockAppError;
use nockapp::noun::slab::NounSlab;
use nockapp::noun::{AtomExt, NounExt};
use nockvm::noun::{Atom, D, T};
use nockvm_macros::tas;
use tempfile::tempdir;
use tracing::{error, info, instrument, warn};

pub enum MiningWire {
    Mined,
    Candidate,
    SetPubKey,
    Enable,
}

impl MiningWire {
    pub fn verb(&self) -> &'static str {
        match self {
            MiningWire::Mined => "mined",
            MiningWire::SetPubKey => "setpubkey",
            MiningWire::Candidate => "candidate",
            MiningWire::Enable => "enable",
        }
    }
}

impl Wire for MiningWire {
    const VERSION: u64 = 1;
    const SOURCE: &'static str = "miner";

    fn to_wire(&self) -> nockapp::wire::WireRepr {
        let tags = vec![self.verb().into()];
        nockapp::wire::WireRepr::new(MiningWire::SOURCE, MiningWire::VERSION, tags)
    }
}

#[derive(Debug, Clone)]
pub struct MiningKeyConfig {
    pub share: u64,
    pub m: u64,
    pub keys: Vec<String>,
}

impl FromStr for MiningKeyConfig {
    type Err = String;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        // Expected format: "share,m:key1,key2,key3"
        let parts: Vec<&str> = s.split(':').collect();
        if parts.len() != 2 {
            return Err("Invalid format. Expected 'share,m:key1,key2,key3'".to_string());
        }

        let share_m: Vec<&str> = parts[0].split(',').collect();
        if share_m.len() != 2 {
            return Err("Invalid share,m format".to_string());
        }

        let share = share_m[0].parse::<u64>().map_err(|e| e.to_string())?;
        let m = share_m[1].parse::<u64>().map_err(|e| e.to_string())?;
        let keys: Vec<String> = parts[1].split(',').map(String::from).collect();

        Ok(MiningKeyConfig { share, m, keys })
    }
}

pub fn create_mining_driver(
    mining_config: Option<Vec<MiningKeyConfig>>,
    mine: bool,
    init_complete_tx: Option<tokio::sync::oneshot::Sender<()>>,
) -> IODriverFn {
    Box::new(move |mut handle| {
        Box::pin(async move {
            info!("Initializing mining driver with config: {:?}", mining_config);
            
            let Some(configs) = mining_config else {
                info!("No mining config provided, disabling mining");
                enable_mining(&handle, false).await?;

                if let Some(tx) = init_complete_tx {
                    tx.send(()).map_err(|_| {
                        error!("Failed to send driver initialization for mining driver");
                        NockAppError::OtherError
                    })?;
                }

                return Ok(());
            };

            // Configure mining keys
            if configs.len() == 1
                && configs[0].share == 1
                && configs[0].m == 1
                && configs[0].keys.len() == 1
            {
                info!("Setting single mining key");
                set_mining_key(&handle, configs[0].keys[0].clone()).await?;
            } else {
                info!("Setting advanced mining keys configuration");
                set_mining_key_advanced(&handle, configs).await?;
            }

            enable_mining(&handle, mine).await?;
            info!("Mining enabled: {}", mine);

            if let Some(tx) = init_complete_tx {
                tx.send(()).map_err(|_| {
                    error!("Failed to send driver initialization for mining driver");
                    NockAppError::OtherError
                })?;
            }

            if !mine {
                return Ok(());
            }

            let mut next_attempt: Option<NounSlab> = None;
            let mut current_attempt: tokio::task::JoinSet<()> = tokio::task::JoinSet::new();
            
            // Limit mining cores to prevent resource exhaustion
            let num_cores = std::thread::available_parallelism().map(|p| p.get()).unwrap_or(1);
            let mining_cores = if num_cores > 4 { 2 } else { 1 }; // Limit to max 2 cores
            info!("Using {} mining cores", mining_cores);

            // Add resource monitoring
            let mut last_resource_check = std::time::Instant::now();
            let resource_check_interval = Duration::from_secs(30);

            loop {
                // Check system resources periodically
                if last_resource_check.elapsed() >= resource_check_interval {
                    if let Err(e) = check_system_resources() {
                        error!("System resource check failed: {}", e);
                        // Optionally pause mining or reduce cores
                    }
                    last_resource_check = std::time::Instant::now();
                }

                tokio::select! {
                    effect_res = handle.next_effect() => {
                        let Ok(effect) = effect_res else {
                            error!("Error receiving effect in mining driver: {:?}", effect_res);
                            continue;
                        };
                        
                        let Ok(effect_cell) = (unsafe { effect.root().as_cell() }) else {
                            warn!("Invalid effect cell received");
                            drop(effect);
                            continue;
                        };

                        if effect_cell.head().eq_bytes("mine") {
                            info!("Received new mining candidate");
                            let candidate_slab = {
                                let mut slab = NounSlab::new();
                                slab.copy_into(effect_cell.tail());
                                slab
                            };
                            
                            if !current_attempt.is_empty() {
                                info!("Queuing next mining attempt");
                                next_attempt = Some(candidate_slab);
                            } else {
                                for i in 0..mining_cores {
                                    let (cur_handle, attempt_handle) = handle.dup();
                                    handle = cur_handle;
                                    info!("Spawning mining attempt {}", i + 1);
                                    current_attempt.spawn(mining_attempt(candidate_slab.clone(), attempt_handle));
                                }
                            }
                        }
                    },
                    mining_attempt_res = current_attempt.join_next(), if !current_attempt.is_empty() => {
                        match mining_attempt_res {
                            Some(Ok(())) => info!("Mining attempt completed successfully"),
                            Some(Err(e)) => error!("Error during mining attempt: {:?}", e),
                            None => warn!("Mining attempt completed with no result"),
                        }

                        let Some(candidate_slab) = next_attempt else {
                            continue;
                        };
                        next_attempt = None;
                        
                        for i in 0..mining_cores {
                            let (cur_handle, attempt_handle) = handle.dup();
                            handle = cur_handle;
                            info!("Spawning next mining attempt {}", i + 1);
                            current_attempt.spawn(mining_attempt(candidate_slab.clone(), attempt_handle));
                        }
                    }
                }
            }
        })
    })
}

#[instrument(skip(candidate, handle))]
pub async fn mining_attempt(candidate: NounSlab, handle: NockAppHandle) -> () {
    info!("Starting mining attempt");
    
    let snapshot_dir = match tokio::task::spawn_blocking(|| tempdir()).await {
        Ok(Ok(dir)) => dir,
        Ok(Err(e)) => {
            error!("Failed to create temporary directory: {}", e);
            return;
        }
        Err(e) => {
            error!("Failed to spawn blocking task for tempdir: {}", e);
            return;
        }
    };

    let hot_state = zkvm_jetpack::hot::produce_prover_hot_state();
    let snapshot_path_buf = snapshot_dir.path().to_path_buf();
    let jam_paths = JamPaths::new(snapshot_dir.path());

    // Load kernel with timeout
    let kernel = match tokio::time::timeout(
        Duration::from_secs(30),
        Kernel::load_with_hot_state_huge(snapshot_path_buf, jam_paths, KERNEL, &hot_state, false)
    ).await {
        Ok(Ok(kernel)) => kernel,
        Ok(Err(e)) => {
            error!("Failed to load mining kernel: {}", e);
            return;
        }
        Err(_) => {
            error!("Timeout while loading mining kernel");
            return;
        }
    };

    info!("Mining kernel loaded successfully");

    let effects_slab = match kernel.poke(MiningWire::Candidate.to_wire(), candidate).await {
        Ok(slab) => slab,
        Err(e) => {
            error!("Failed to poke mining kernel with candidate: {}", e);
            return;
        }
    };

    for effect in effects_slab.to_vec() {
        let Ok(effect_cell) = (unsafe { effect.root().as_cell() }) else {
            warn!("Invalid effect cell in mining attempt");
            drop(effect);
            continue;
        };

        if effect_cell.head().eq_bytes("command") {
            if let Err(e) = handle.poke(MiningWire::Mined.to_wire(), effect).await {
                error!("Failed to poke nockchain with mined PoW: {}", e);
            } else {
                info!("Successfully submitted mined PoW");
            }
        }
    }
}

// Add a function to check system resources
fn check_system_resources() -> Result<(), String> {
    // Get system memory info
    let mem_info = sys_info::mem_info().map_err(|e| format!("Failed to get memory info: {}", e))?;
    let total_mem = mem_info.total;
    let free_mem = mem_info.free;
    let used_percent = ((total_mem - free_mem) as f64 / total_mem as f64) * 100.0;

    // Log memory usage
    info!("Memory usage: {:.1}% used ({} MB free of {} MB total)", 
          used_percent, free_mem / 1024 / 1024, total_mem / 1024 / 1024);

    // Warn if memory usage is high
    if used_percent > 90.0 {
        warn!("High memory usage detected: {:.1}%", used_percent);
    }

    Ok(())
}

#[instrument(skip(handle, pubkey))]
async fn set_mining_key(
    handle: &NockAppHandle,
    pubkey: String,
) -> Result<PokeResult, NockAppError> {
    let mut set_mining_key_slab = NounSlab::new();
    let set_mining_key = Atom::from_value(&mut set_mining_key_slab, "set-mining-key")
        .expect("Failed to create set-mining-key atom");
    let pubkey_cord =
        Atom::from_value(&mut set_mining_key_slab, pubkey).expect("Failed to create pubkey atom");
    let set_mining_key_poke = T(
        &mut set_mining_key_slab,
        &[D(tas!(b"command")), set_mining_key.as_noun(), pubkey_cord.as_noun()],
    );
    set_mining_key_slab.set_root(set_mining_key_poke);

    handle
        .poke(MiningWire::SetPubKey.to_wire(), set_mining_key_slab)
        .await
}

async fn set_mining_key_advanced(
    handle: &NockAppHandle,
    configs: Vec<MiningKeyConfig>,
) -> Result<PokeResult, NockAppError> {
    let mut set_mining_key_slab = NounSlab::new();
    let set_mining_key_adv = Atom::from_value(&mut set_mining_key_slab, "set-mining-key-advanced")
        .expect("Failed to create set-mining-key-advanced atom");

    // Create the list of configs
    let mut configs_list = D(0);
    for config in configs {
        // Create the list of keys
        let mut keys_noun = D(0);
        for key in config.keys {
            let key_atom =
                Atom::from_value(&mut set_mining_key_slab, key).expect("Failed to create key atom");
            keys_noun = T(&mut set_mining_key_slab, &[key_atom.as_noun(), keys_noun]);
        }

        // Create the config tuple [share m keys]
        let config_tuple = T(
            &mut set_mining_key_slab,
            &[D(config.share), D(config.m), keys_noun],
        );

        configs_list = T(&mut set_mining_key_slab, &[config_tuple, configs_list]);
    }

    let set_mining_key_poke = T(
        &mut set_mining_key_slab,
        &[D(tas!(b"command")), set_mining_key_adv.as_noun(), configs_list],
    );
    set_mining_key_slab.set_root(set_mining_key_poke);

    handle
        .poke(MiningWire::SetPubKey.to_wire(), set_mining_key_slab)
        .await
}

//TODO add %set-mining-key-multisig poke
#[instrument(skip(handle))]
async fn enable_mining(handle: &NockAppHandle, enable: bool) -> Result<PokeResult, NockAppError> {
    let mut enable_mining_slab = NounSlab::new();
    let enable_mining = Atom::from_value(&mut enable_mining_slab, "enable-mining")
        .expect("Failed to create enable-mining atom");
    let enable_mining_poke = T(
        &mut enable_mining_slab,
        &[D(tas!(b"command")), enable_mining.as_noun(), D(if enable { 0 } else { 1 })],
    );
    enable_mining_slab.set_root(enable_mining_poke);
    handle
        .poke(MiningWire::Enable.to_wire(), enable_mining_slab)
        .await
}
