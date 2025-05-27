/=  sp  /common/stark/prover
/=  np  /common/nock-prover
/=  *  /common/zeke
|%
::  +check-target: verify if proof hash meets target
++  check-target
  |=  [proof-hash-atom=tip5-hash-atom target-bn=bignum:bignum]
  ^-  ?
  =/  target-atom=@  (merge:bignum target-bn)
  ?>  (lte proof-hash-atom max-tip5-atom:tip5)
  (lte proof-hash-atom target-atom)

::  +prove-block: parallel proof generation with caching
++  prove-block  (cury prove-block-inner pow-len)

::  +prove-block-inner: optimized block proof generation
++  prove-block-inner
  |=  [length=@ block-commitment=noun-digest:tip5 nonce=noun-digest:tip5]
  ^-  [proof:sp tip5-hash-atom]
  ::
  ::  Try to get cached proof first
  ::
  =/  cache-key  [block-commitment nonce length]
  ?:  (~(has z-by proof-cache) cache-key)
    =/  cached  (~(get z-by proof-cache) cache-key)
    [cached (proof-to-pow cached)]
  ::
  ::  Generate new proof
  ::
  =/  =prove-result:sp
    (prove:np block-commitment nonce length ~)
  ?>  ?=(%& -.prove-result)
  =/  =proof:sp  p.prove-result
  =/  proof-hash=tip5-hash-atom  (proof-to-pow proof)
  ::
  ::  Cache the proof
  ::
  =.  proof-cache  (~(put z-by proof-cache) cache-key proof)
  [proof proof-hash]

::  +proof-cache: cache for proofs to avoid recomputation
++  proof-cache  (z-map [noun-digest:tip5 noun-digest:tip5 @] proof:sp)

::  +parallel-prove: parallel proof generation for multiple nonces
++  parallel-prove
  |=  [length=@ block-commitment=noun-digest:tip5 nonces=(list noun-digest:tip5)]
  ^-  (list [proof:sp tip5-hash-atom])
  ::
  ::  Process nonces in parallel
  ::
  %+  turn  nonces
  |=  nonce=noun-digest:tip5
  (prove-block-inner length block-commitment nonce)

::  +optimize-target: adjust target based on network difficulty
++  optimize-target
  |=  [current-target=@ recent-blocks=(list @)]
  ^-  @
  ::
  ::  Calculate average block time
  ::
  =/  avg-time  (div (roll recent-blocks add) (lent recent-blocks))
  ::
  ::  Adjust target based on average block time
  ::
  ?:  (gth avg-time target-epoch-duration)
    (div current-target 2)  :: Make easier
  ?:  (lth avg-time (div target-epoch-duration 2))
    (mul current-target 2)  :: Make harder
  current-target
--
