import "IERC20.spec";

methods {
    function balanceOf(address) external returns (uint256) envfree;
    function delegatesVotesCount(address, address) external returns (uint256) envfree;
    function containsDelegate(address, address) external returns (bool) envfree;
    function totalSupply() external returns (uint256) envfree;
    /// EIP712 interface
    function eip712Domain() external returns 
        (bytes1,string memory,string memory,uint256,address,bytes32,uint256[] memory) =>
        NONDET DELETE(false); /// To prevent analysis errors

    function delegates(address) external returns (address[]) envfree;
    function userDelegatedVotes(address) external returns (uint256) envfree;
    function maxDelegates() external returns (uint256) envfree;
    function canContractExceedMaxDelegates(address) external returns (bool) envfree;
    function delegateCount(address) external returns (uint256) envfree;
}

/// gauge rules:
///    total weight must always equal sum of total weight
///    sum of total weight equals sum of weight of active gauges
///    a gauge can be deprecated or active, but never both
///    a gauge can only be in either active or deprecated list
///    
