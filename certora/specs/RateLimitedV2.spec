/// 1 munging --- change solidity code to write spec
/// 2 helpers --- exposing additional things and behaviors you don't have access to
/// 3 harnessing --- add solidity code to expose variables and make it play nice with the prover

methods {
    /// no side affects
    // function emergencyAction(CoreRef.Call[] calldata) external returns (bytes[]) => NONDET;
    /// summarize with cvl function or constant
    function emergencyAction(CoreRef.Call[]) external returns (bytes[]) => NONDET;

    /// envfree
    function bufferCap() external returns (uint128) envfree;
    function rateLimitPerSecond() external returns (uint128) envfree;
    function MAX_RATE_LIMIT_PER_SECOND() external returns (uint256) envfree;
    function lastBufferUsedTime() external returns (uint32) envfree;
    function bufferStored() external returns (uint224) envfree;
}

// /// ensure we can reach assert false for all external calls
// rule sanity(method f) {
//     env e;
//     calldataarg args;
//     f(e, args);
//     assert false;
// }

/// State Transitions
/// if depleting, amount <= buffer()
/// after depletion, buffer() == buffer() - amount
/// - lastBufferUsedTime == block.timestamp if amount != 0
/// - bufferStored == buffer()
/// if replenishing
/// - lastBufferUsedTime == block.timestamp if amount != 0 && bufferCap != newBuffer
/// - bufferStored() <= bufferCap

/// ----------------------
/// ----- Invariants -----
/// ----------------------

/// 1). buffer() <= bufferCap
/// 2). bufferStored <= bufferCap
/// 3). rateLimitPerSecond <= MAX_RATE_LIMIT_PER_SECOND

invariant bufferLteBufferCap(env e)
    buffer(e) <= assert_uint256(bufferCap());

invariant bufferStoredLteBufferCap(env e)
    to_mathint(bufferStored()) <= to_mathint(bufferCap());

invariant maxRateLimitPerSecond()
    to_mathint(rateLimitPerSecond()) <= to_mathint(MAX_RATE_LIMIT_PER_SECOND());

ghost mathint countLBUTWrite {
    init_state axiom countLBUTWrite == 0;
}

ghost mathint countBSWrite {
    init_state axiom countBSWrite == 0;
}

/* update ghost on changes to lastBufferUsedTime */
hook Sstore lastBufferUsedTime uint32 new_last_buffer_used_time (uint32 old_last_buffer_used_time) STORAGE {
  countLBUTWrite = countLBUTWrite + 1;
}

/* update ghost on changes to bufferStored */
hook Sstore bufferStored uint224 new_buffer_stored (uint224 old_buffer_stored) STORAGE {
  countBSWrite = countBSWrite + 1;
}

invariant bufferStoredAlwaysCausesLastBufferUsedTimeWrite()
    countBSWrite == countLBUTWrite;

/// -------------------
/// ------ Rules ------
/// -------------------

/// last buffer used time monotonically increasing
rule lastBufferUsedTimeCorrectlyUpdated(env e, method f) {
    calldataarg args;

    uint32 lastBufferUsedTimePre = lastBufferUsedTime();
    require to_mathint(lastBufferUsedTimePre) <= to_mathint(e.block.timestamp);

    f(e, args);

    uint32 lastBufferUsedTimePost = lastBufferUsedTime();

    assert lastBufferUsedTimePre <= lastBufferUsedTimePost, "incorrect state transition";
    assert to_mathint(lastBufferUsedTimePost) <= to_mathint(e.block.timestamp), "incorrect post timestamp set, cannot be in the future";
}

/// buffer does not change
rule noStateChanges(env e, method f) 
filtered {
    f ->
    f.selector != sig:setBufferCap(uint128).selector &&
    f.selector != sig:setRateLimitPerSecond(uint128).selector &&
    f.selector != sig:replenishBuffer(uint256).selector &&
    f.selector != sig:depleteBuffer(uint256).selector
} {
    calldataarg args;

    uint32 lastBufferUsedTimePre = lastBufferUsedTime();
    uint224 bufferStoredPre = bufferStored();
    uint256 lastBufferPre = buffer(e);

    f(e, args);

    assert lastBufferUsedTimePre == lastBufferUsedTime(), "last buffer used time state change";
    assert bufferStoredPre == bufferStored(), "last buffer stored state change";
    assert lastBufferPre == buffer(e), "buffer state change";
}

rule timePassingAccruesBuffer(env e1, env e2) {
    uint256 lastBufferEnv1 = buffer(e1);
    uint256 lastBufferEnv2 = buffer(e2);

    require rateLimitPerSecond() != 0;

    assert ((e1.block.timestamp > e2.block.timestamp))
         => lastBufferEnv1 >= lastBufferEnv2;

    bool e1Gte2 = e1.block.timestamp > e2.block.timestamp;
    bool e2Gte1 = e2.block.timestamp > e1.block.timestamp;

    assert (to_mathint(lastBufferEnv1) < to_mathint(bufferCap()) && e1Gte2) => lastBufferEnv1 > lastBufferEnv2;
    assert (to_mathint(lastBufferEnv2) < to_mathint(bufferCap()) && e2Gte1) => lastBufferEnv2 > lastBufferEnv1;
}

rule lastBufferUsedTimeAlwaysMonotonicallyIncreasingDeplete(env e, uint256 amount) {
    uint32 lastBufferUsedTimePre = lastBufferUsedTime();

    require to_mathint(lastBufferUsedTimePre) < to_mathint(e.block.timestamp);
    require amount <= buffer(e);

    depleteBuffer(e, amount);

    uint32 lastBufferUsedTimePost = lastBufferUsedTime();

    assert lastBufferUsedTimePost > lastBufferUsedTimePre, "buffer used time incorrect";
}

rule lastBufferUsedTimeAlwaysMonotonicallyIncreasingReplenish(env e, uint256 amount) {
    uint32 lastBufferUsedTimePre = lastBufferUsedTime();

    require to_mathint(lastBufferUsedTimePre) < to_mathint(e.block.timestamp);
    require amount <= buffer(e);
    require to_mathint(buffer(e)) < to_mathint(bufferCap());

    replenishBuffer(e, amount);

    uint32 lastBufferUsedTimePost = lastBufferUsedTime();

    assert lastBufferUsedTimePost > lastBufferUsedTimePre, "buffer used time incorrect";
}


rule lastBufferUsedTimeMonotonicallyIncreasing(env e, method f) {
    uint32 lastBufferUsedTimePre = lastBufferUsedTime();
    uint256 bufferPre = buffer(e);

    require to_mathint(lastBufferUsedTimePre) < to_mathint(e.block.timestamp);

    calldataarg args;

    /// possible function calls:
    ///  - deplete buffer
    ///  - replenish buffer --- if already at bufferCap, no state changes
    ///  - setBufferCap
    ///  - setRateLimitPerSecond
    f(e, args);

    uint32 lastBufferUsedTimePost = lastBufferUsedTime();

    assert lastBufferUsedTimePost >= lastBufferUsedTimePre, "buffer used time incorrect";
}
