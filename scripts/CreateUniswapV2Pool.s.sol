// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Script, console} from "@forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IUniswapRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
}

/// @notice deploy and init a balancer weighted pool with 50%/50% ratio
/// forge script --rpc-url {RPC URL} ./scripts/CreateBalancerWeightedPool.s.sol:DeployBalancerPool --broadcast
contract DeployBalancerPool is Script {
    uint256 public PRIVATE_KEY;
    IUniswapRouter public UNISWAP_ROUTER =
        IUniswapRouter(0xC532a74256D3Db42D0Bf7a0400fEFDbad7694008);

    // REPLACE WITH YOUR DATA
    address token0 = 0x7b8b4418990e4Daf35F5c7f0165DC487b1963641; // USDC
    uint256 amount0 = 1_000_0000e6;
    address token1 = 0x9F07498d9f4903B10dB57a3Bd1D91b6B64AEd61e; // sDAI
    uint256 amount1 = 10_000_000e18;

    function _parseEnv() internal {
        // Default behavior: use Anvil 0 private key
        PRIVATE_KEY = vm.envOr(
            "ETH_PRIVATE_KEY",
            77814517325470205911140941194401928579557062014761831930645393041380819009408
        );
    }

    function run() public {
        _parseEnv();
        address deployerAddress = vm.addr(PRIVATE_KEY);
        console.log("DEPLOYER: %s", deployerAddress);

        vm.startBroadcast(PRIVATE_KEY);
        ERC20(token0).approve(address(UNISWAP_ROUTER), amount0);
        ERC20(token1).approve(address(UNISWAP_ROUTER), amount1);
        UNISWAP_ROUTER.addLiquidity(
            token0,
            token1,
            amount0,
            amount1,
            amount0,
            amount1,
            deployerAddress,
            block.timestamp + 1000
        );
        vm.stopBroadcast();
    }
}
