// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IWeightedPoolFactory {
    function create(
        string memory name,
        string memory symbol,
        address[] memory tokens,
        uint256[] memory normalizedWeights,
        address[] memory rateProviders,
        uint256 swapFeePercentage,
        address owner,
        bytes32 salt
    ) external returns (address);
}

interface IVault {
    function joinPool(
        bytes32 poolId,
        address sender,
        address recipient,
        JoinPoolRequest memory request
    ) external payable;
}

struct JoinPoolRequest {
    address[] assets;
    uint256[] maxAmountsIn;
    bytes userData;
    bool fromInternalBalance;
}

interface IPool {
    function getPoolId() external returns (bytes32);
}

/// @notice deploy and init a balancer weighted pool with 50%/50% ratio
/// forge script --rpc-url {RPC URL} ./scripts/CreateBalancerWeightedPool.s.sol:DeployBalancerPool --broadcast
contract DeployBalancerPool is Script {
    uint256 public PRIVATE_KEY;
    IWeightedPoolFactory public factory =
        IWeightedPoolFactory(0x7920BFa1b2041911b354747CA7A6cDD2dfC50Cfd);
    IVault public vault = IVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    // REPLACE WITH YOUR DATA
    string name = "50ecgUSDC-50ecgsDAI";
    string symbol = "50ecgUSDC-50ecgsDAI";
    address token0 = 0xe9248437489bC542c68aC90E178f6Ca3699C3F6b;
    uint256 amount0 = 50000000000000;
    address token1 = 0xeeF0AB67262046d5bED00CE9C447e08D92b8dA61;
    uint256 amount1 = 50000000000000000000000000;

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();
        address[] memory tokens = new address[](2);
        tokens[0] = token0;
        tokens[1] = token1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amount0;
        amounts[1] = amount1;

        console.log("name: %s", name);
        console.log("symbol: %s", symbol);

        vm.startBroadcast(PRIVATE_KEY);
        // create the pool
        bytes32 poolId = createPool(tokens);
        console.logBytes32(poolId);
        // approve tokens
        approveTokensToVault(tokens, amounts);
        // join the pool with initial values
        initPool(poolId, tokens, amounts);
        vm.stopBroadcast();
    }

    function createPool(
        address[] memory tokens
    ) public returns (bytes32 poolId) {
        uint256[] memory normalizedWeights = new uint256[](2);
        normalizedWeights[0] = 0.5e18;
        normalizedWeights[1] = 0.5e18;
        address[] memory rateProviders = new address[](2);
        rateProviders[0] = 0x0000000000000000000000000000000000000000;
        rateProviders[1] = 0x0000000000000000000000000000000000000000;
        uint256 swapFeePercentage = 0.003e18;
        address owner = vm.addr(PRIVATE_KEY);
        bytes32 salt = randomBytes32();
        address poolAddress = factory.create(
            name,
            symbol,
            tokens,
            normalizedWeights,
            rateProviders,
            swapFeePercentage,
            owner,
            salt
        );

        console.log("poolAddress: %s", poolAddress);

        poolId = IPool(poolAddress).getPoolId();
    }

    function approveTokensToVault(
        address[] memory tokens,
        uint256[] memory amounts
    ) public {
        for (uint8 i = 0; i < tokens.length; i++) {
            ERC20(tokens[i]).approve(address(vault), amounts[i]);
        }
    }

    function initPool(
        bytes32 poolId,
        address[] memory tokens,
        uint256[] memory amounts
    ) public {
        // this encodes the data for the INIT join
        bytes memory dataEncoded = abi.encode(uint256(0), amounts);

        JoinPoolRequest memory request = JoinPoolRequest({
            assets: tokens,
            maxAmountsIn: amounts,
            userData: dataEncoded,
            fromInternalBalance: false
        });
        address deployerAddress = vm.addr(PRIVATE_KEY);

        vault.joinPool(poolId, deployerAddress, deployerAddress, request);
    }

    function randomBytes32() public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.timestamp, msg.sender));
    }
}
