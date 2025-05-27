/=  dk  /apps/dumbnet/lib/types
/=  sp  /common/stark/prover
/=  dumb-transact  /common/tx-engine
/=  *  /common/zoon
::
:: everything to do with mining and mining state
::
|_  [m=mining-state:dk =blockchain-constants:dumb-transact]
+*  t  ~(. dumb-transact blockchain-constants)
+|  %admin
::  +set-mining: set .mining
++  set-mining
  |=  mine=?
  ^-  mining-state:dk
  m(mining mine)
::
::  +set-pubkey: set .pubkey
++  set-pubkeys
  |=  pks=(list lock:t)
  ^-  mining-state:dk
  =.  pubkeys.m
    (~(gas z-in *(z-set lock:t)) pks)
  m
::
::  +set-shares validate and set .shares
++  set-shares
  |=  shr=(list [lock:t @])
  =/  s=shares:t  (~(gas z-by *(z-map lock:t @)) shr)
  ?.  (validate:shares:t s)
    ~|('invalid shares' !!)
  m(shares s)
::
+|  %candidate-block
++  set-pow
  |=  prf=proof:sp
  ^-  mining-state:dk
  m(pow.candidate-block (some prf))
::
++  set-digest
  ^-  mining-state:dk
  m(digest.candidate-block (compute-digest:page:t candidate-block.m))
::
::  +update-timestamp: updates timestamp on candidate block if needed
::
::    this should be run every time we get a poke.
++  update-timestamp
  |=  now=@da
  ^-  mining-state:dk
  ?:  |(=(*page:t candidate-block.m) !mining.m)
    ::  not mining or no candidate block is set so no need to update timestamp
    m
  ?:  %+  gte  timestamp.candidate-block.m
      (time-in-secs:page:t (sub now update-candidate-timestamp-interval:t))
    ::  has not been ~m2, so leave timestamp alone
    m
  =.  timestamp.candidate-block.m  (time-in-secs:page:t now)
  =/  print-var
    %-  trip
    ^-  @t
    %^  cat  3
      'candidate block timestamp updated: '
    (scot %$ timestamp.candidate-block.m)
  ~>  %slog.[0 [%leaf print-var]]
  m
::
::  +tx-pool: manages pending transactions
++  tx-pool
  |_  [pool=(z-map hash:t raw-tx:t) fees=(z-map hash:t coins:t)]
  ++  add
    |=  [raw=raw-tx:t fee=coins:t]
    ^-  (pair (z-map hash:t raw-tx:t) (z-map hash:t coins:t))
    ::
    ::  Add transaction to pool if it has higher fees than existing one
    ::
    =/  id=hash:t  id.raw
    ?:  (~(has z-by fees) id)
      ?:  (gth fee (~(get z-by fees) id))
        ::
        ::  Replace with higher fee transaction
        ::
        [(~(put z-by pool) id raw) (~(put z-by fees) id fee)]
      [pool fees]
    ::
    ::  Add new transaction
    ::
    [(~(put z-by pool) id raw) (~(put z-by fees) id fee)]
  ++  remove
    |=  id=hash:t
    ^-  (pair (z-map hash:t raw-tx:t) (z-map hash:t coins:t))
    [(~(del z-by pool) id) (~(del z-by fees) id)]
  ++  get-highest-fee
    |=  n=@
    ^-  (list [hash:t raw-tx:t])
    ::
    ::  Get top N transactions by fee
    ::
    =/  sorted=(list [hash:t coins:t])
      %+  sort  ~(tap z-by fees)
      |=  [[id1=hash:t fee1=coins:t] [id2=hash:t fee2=coins:t]]
      (gth fee1 fee2)
    =/  top-n=(list hash:t)
      %+  turn  (scag n sorted)
      |=  [id=hash:t fee=coins:t]
      id
    %+  turn  top-n
    |=  id=hash:t
    [id (~(get z-by pool) id)]
  --

::  +process-tx-batch: process a batch of transactions
++  process-tx-batch
  |=  [raws=(list raw-tx:t) min=_m]
  ^-  mining-state:dk
  ::
  ::  Process transactions in batches for better performance
  ::
  =/  pool=tx-pool  [*(z-map hash:t raw-tx:t) *(z-map hash:t coins:t)]
  =/  new-min=_m  min
  ::
  ::  Add all transactions to pool
  ::
  =/  pool  %+  roll  raws
    |=  [raw=raw-tx:t p=tx-pool]
    (add:tx-pool p raw (fee:raw-tx:t raw))
  ::
  ::  Process highest fee transactions first
  ::
  =/  to-process=(list [hash:t raw-tx:t])
    (get-highest-fee:tx-pool pool 100)  :: Process up to 100 transactions
  ::
  ::  Process each transaction
  ::
  %+  roll  to-process
  |=  [[id=hash:t raw=raw-tx:t] min=_m]
  (heard-new-tx raw)

::  +heard-new-tx: potentially changes candidate block in reaction to a raw-tx
++  heard-new-tx
  |=  raw=raw-tx:t
  ^-  mining-state:dk
  ~>  %slog.[3 'miner: heard-new-tx']
  ~>  %slog.[3 (cat 3 'miner: heard-new-tx: raw-tx: ' (to-b58:hash:t id.raw))]
  ::
  ::  if the mining pubkey is not set, do nothing
  ?:  =(*(z-set lock:t) pubkeys.m)  m
  ::
  ::  check to see if block is valid with tx - this checks whether the inputs
  ::  exist, whether the new size will exceed block size, and whether timelocks
  ::  are valid
  =/  tx=(unit tx:t)  (mole |.((new:tx:t raw height.candidate-block.m)))
  ?~  tx
    ::  invalid tx. we don't emit a %liar effect from this because it might
    ::  just not be valid for this particular block
    m
  =/  new-acc=(unit tx-acc:t)
    (process:tx-acc:t candidate-acc.m u.tx height.candidate-block.m)
  ?~  new-acc
    m
  ::
  ::  we can add tx to candidate-block
  ::
  =.  tx-ids.candidate-block.m
    (~(put z-in tx-ids.candidate-block.m) id.raw)
  =/  old-fees=coins:t  fees.candidate-acc.m
  =.  candidate-acc.m  u.new-acc
  =/  new-fees=coins:t  fees.candidate-acc.m
  ::
  ::  check if new-fees != old-fees to determine if split should be recalculated.
  ::  since we don't have replace-by-fee
  ::
  ?:  =(new-fees old-fees)
    ::  fees are equal so no need to recalculate split
    m
  ::
  ::  fees are unequal. for this miner, fees are only ever monotonically
  ::  incremented and so this assertion should never fail.
  ::
  ?>  (gth new-fees old-fees)
  =/  fee-diff=coins:t  (sub new-fees old-fees)
  ::
  ::  compute old emission+fees
  ::
  =/  old-assets=coins:t
    %+  roll  ~(val z-by coinbase.candidate-block.m)
    |=  [c=coins:t sum=coins:t]
    (add c sum)
  =/  new-assets=coins:t  (add old-assets fee-diff)
  =.  coinbase.candidate-block.m
    (new:coinbase-split:t new-assets shares.m)
  m
::
::  +block-template: pre-computed block template
++  block-template
  |_  [template=page:t timestamp=@]
  ++  update-timestamp
    |=  now=@da
    ^-  block-template
    ?:  %+  gte  timestamp
        (time-in-secs:page:t (sub now update-candidate-timestamp-interval:t))
      [template timestamp]
    [template (time-in-secs:page:t now)]
  --

::  +optimize-candidate: optimize block candidate with better transaction selection
++  optimize-candidate
  |=  [candidate=page:t txs=(list raw-tx:t)]
  ^-  page:t
  ::
  ::  Sort transactions by fee per byte
  ::
  =/  fee-per-byte=(list [raw-tx:t @])
    %+  turn  txs
    |=  raw=raw-tx:t
    =/  size=@  (size:raw-tx:t raw)
    =/  fee=@  (fee:raw-tx:t raw)
    [raw (div fee size)]
  =/  sorted-txs=(list raw-tx:t)
    %+  turn  (sort fee-per-byte |= [[a=raw-tx:t b=@] [c=raw-tx:t d=@]] (gth b d))
    |=  [raw=raw-tx:t fee=@]
    raw
  ::
  ::  Fill block with highest fee-per-byte transactions
  ::
  =/  new-candidate=page:t  candidate
  =/  current-size=@  0
  =/  max-size=@  max-block-size
  ::
  ::  Add transactions until block is full
  ::
  %+  roll  sorted-txs
  |=  [raw=raw-tx:t candidate=page:t]
  =/  size=@  (size:raw-tx:t raw)
  ?:  (gth (add current-size size) max-size)
    candidate
  =/  tx=(unit tx:t)  (mole |.((new:tx:t raw height.candidate)))
  ?~  tx  candidate
  =/  new-acc=(unit tx-acc:t)
    (process:tx-acc:t candidate-acc.candidate u.tx height.candidate)
  ?~  new-acc  candidate
  ::
  ::  Update candidate with new transaction
  ::
  =.  tx-ids.candidate  (~(put z-in tx-ids.candidate) id.raw)
  =.  candidate-acc.candidate  u.new-acc
  =.  current-size  (add current-size size)
  candidate

::  +heard-new-block: optimized block candidate generation
++  heard-new-block
  |=  [c=consensus-state:dk p=pending-state:dk now=@da]
  ^-  mining-state:dk
  ::
  ::  Sanity checks
  ::
  ?~  heaviest-block.c
    ~>  %slog.[0 leaf+"attempted to generate new candidate block when we have no genesis block"]
    m
  ?:  =(u.heaviest-block.c parent.candidate-block.m)
    ~>  %slog.[0 leaf+"heaviest block unchanged, do not generate new candidate block"]
    m
  ?:  =(*(z-set lock:t) pubkeys.m)
    ~>  %slog.[0 leaf+"no pubkey(s) set so no new candidate block will be generated"]
    m
  ::
  ::  Generate optimized candidate block
  ::
  =/  base-candidate=page:t
    %-  new-candidate:page:t
    :*  (to-page:local-page:t (~(got z-by blocks.c) u.heaviest-block.c))
        now
        (~(got z-by targets.c) u.heaviest-block.c)
        shares.m
    ==
  =/  optimized-candidate=page:t
    (optimize-candidate base-candidate ~(val z-by raw-txs.p))
  ::
  ::  Update mining state
  ::
  =.  candidate-block.m  optimized-candidate
  =.  candidate-acc.m
    (new:tx-acc:t (~(get z-by balance.c) u.heaviest-block.c))
  m
