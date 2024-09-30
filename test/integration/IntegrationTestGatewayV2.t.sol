// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.24;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {console} from "@forge-std/console.sol";
import {ECGTest} from "@test/ECGTest.sol";
import {GatewayV2} from "@src/gateway/v2/GatewayV2.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

struct PermitData {
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 deadline;
}

struct ExitPoolRequest {
    address[] tokens;
    uint256[] amounts;
    bytes data;
    bool toInternalBalance;
}

interface IAuraToken {
    function rewardToken() external returns (address);
    function extraRewardsLenght() external returns (uint256);
    function extraRewards(uint256 i) external returns (address);
    function getReward(address who, bool claimExtra) external returns (bool);
    function withdraw(uint256 amount, bool claim) external;
}

interface IBalancerVault {
    function getPoolTokens(bytes32 poolId) external returns (address[] memory tokens, uint256[] memory balances, uint256 lastChangeBlock);
}

contract IntegrationTestGatewayV2 is ECGTest {
    uint256 public alice_private_key = 0x42424242421111111;
    address public alice = vm.addr(alice_private_key);

    GatewayV2 public gw;
    MockERC20 public token;

    function pullToken(uint256 amount) external {
        token.transferFrom(msg.sender, address(this), amount);
    }

    function setUp() public {
        gw = new GatewayV2();
        token = new MockERC20();

        vm.label(alice, "Alice");
        vm.label(address(gw), "gw");
    }

    function testPermitAndSweep() public {
        token.mint(alice, 123);

        // sign permit collateral -> Gateway
        PermitData memory permitCollateral = _getPermitData(
            address(token),
            123,
            address(gw),
            alice,
            alice_private_key
        );

        // build gw calls array
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token),
            abi.encodeWithSignature(
                "permit(address,address,uint256,uint256,uint8,bytes32,bytes32)",
                alice,
                address(gw),
                123,
                permitCollateral.deadline,
                permitCollateral.v,
                permitCollateral.r,
                permitCollateral.s
            )
        );
        calls[1] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            address(token),
            123
        );
        calls[2] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(this),
                50
            )
        );
        calls[3] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(this),
            abi.encodeWithSignature(
                "pullToken(uint256)",
                50
            )
        );
        calls[4] = abi.encodeWithSignature(
            "sweep(address)",
            address(token)
        );

        // call gw
        vm.prank(alice);
        gw.action(abi.encodeWithSignature(
            "multicall(bytes[])",
            calls
        ));

        // check token movements
        assertEq(token.balanceOf(alice), 123 - 50);
        assertEq(token.balanceOf(address(this)), 50);
    }

    function testUniswapV3Flashloan() public {
        address pool = 0xC6962004f452bE9203591991D15f6b388e09E8D0; // Uni-v3 WETH/USDC pool
        address weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
        uint256 flashloanAmount = 100 ether;
        uint256 flashloanFee = flashloanAmount * 500 / 1e6;
        dealToken(weth, alice, flashloanFee);
        token.mint(address(gw), 123);

        // approve weth on gateway
        vm.prank(alice);
        ERC20Permit(weth).approve(address(gw), flashloanFee);

        // build actions
        bytes[] memory withFlashloanCalls = new bytes[](2);
        // arbitrary action
        withFlashloanCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(this),
                50
            )
        );
        // repay flashloan
        withFlashloanCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            weth,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                pool,
                flashloanAmount + flashloanFee
            )
        );

        // call gw
        vm.prank(alice);
        gw.actionWithFlashLoan(
            pool, // address flashloanProvider,
            abi.encodeWithSignature( // bytes memory initiateFlashloanCall,
                "flash(address,uint256,uint256,bytes)",
                address(gw),
                flashloanAmount,
                0,
                ""
            ),
            abi.encodeWithSignature( // bytes memory preFlashloanCall
                "consumeAllowance(address,uint256)",
                weth,
                flashloanFee
            ),
            abi.encodeWithSignature( // bytes memory withFlashloanCall,
                "multicall(bytes[])",
                withFlashloanCalls
            ),
            abi.encodeWithSignature( // bytes memory postFlashloanCall
                "callExternal(address,bytes)",
                address(this),
                abi.encodeWithSignature(
                    "pullToken(uint256)",
                    50
                )
            )
        );

        // check token movements
        assertEq(ERC20Permit(weth).balanceOf(address(this)), 0);
        assertEq(ERC20Permit(weth).balanceOf(address(gw)), 0);
        assertEq(token.balanceOf(address(gw)), 123 - 50);
        assertEq(token.balanceOf(address(this)), 50);
    }

    function testAaveV3Flashloan() public {
        address pool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD; // Aave: Pool v3
        address usdc = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831; // USDC
        uint256 flashloanAmount = 100_000_000; // 100$
        uint256 flashloanFee = 50_000; // 0.05$
        dealToken(usdc, alice, flashloanFee);
        token.mint(address(gw), 123);

        // approve usdc on gateway
        vm.prank(alice);
        ERC20Permit(usdc).approve(address(gw), flashloanFee);

        // build actions
        bytes[] memory withFlashloanCalls = new bytes[](3);
        // arbitrary action
        withFlashloanCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(this),
                50
            )
        );
        // approve flashloan repay
        withFlashloanCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            usdc,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                pool,
                flashloanAmount + flashloanFee
            )
        );
        // check enough funds to repay flashloan
        withFlashloanCalls[2] = abi.encodeWithSignature(
            "checkBalanceAtLeast(address,uint256)",
            usdc,
            flashloanAmount + flashloanFee
        );

        // call gw
        vm.prank(alice);
        gw.actionWithFlashLoan(
            pool, // address flashloanProvider,
            abi.encodeWithSignature( // bytes memory initiateFlashloanCall,
                "flashLoanSimple(address,address,uint256,bytes,uint16)",
                address(gw),
                usdc,
                flashloanAmount,
                "",
                0
            ),
            abi.encodeWithSignature( // bytes memory preFlashloanCall
                "consumeAllowance(address,uint256)",
                usdc,
                flashloanFee
            ),
            abi.encodeWithSignature( // bytes memory withFlashloanCall,
                "multicall(bytes[])",
                withFlashloanCalls
            ),
            abi.encodeWithSignature( // bytes memory postFlashloanCall
                "callExternal(address,bytes)",
                address(this),
                abi.encodeWithSignature(
                    "pullToken(uint256)",
                    50
                )
            )
        );

        // check token movements
        assertEq(ERC20Permit(usdc).balanceOf(address(this)), 0);
        assertEq(ERC20Permit(usdc).balanceOf(address(gw)), 0);
        assertEq(token.balanceOf(address(gw)), 123 - 50);
        assertEq(token.balanceOf(address(this)), 50);
    }

    function testBalancerV2Flashloan() public {
        address vault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8; // Balancer V2 Vault
        address weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1; // WETH
        uint256 flashloanAmount = 100 ether;
        uint256 flashloanFee = 0;
        dealToken(weth, alice, flashloanFee);
        token.mint(address(gw), 123);

        // approve weth on gateway
        vm.prank(alice);
        ERC20Permit(weth).approve(address(gw), flashloanFee);

        // build actions
        bytes[] memory withFlashloanCalls = new bytes[](2);
        // arbitrary action
        withFlashloanCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(token),
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(this),
                50
            )
        );
        // repay flashloan
        withFlashloanCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            weth,
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                vault,
                flashloanAmount + flashloanFee
            )
        );

        // call gw
        address[] memory tokens = new address[](1);
        tokens[0] = weth;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = flashloanAmount;
        vm.prank(alice);
        gw.actionWithFlashLoan(
            vault, // address flashloanProvider,
            abi.encodeWithSignature( // bytes memory initiateFlashloanCall,
                "flashLoan(address,address[],uint256[],bytes)",
                address(gw),
                tokens,
                amounts,
                ""
            ),
            abi.encodeWithSignature( // bytes memory preFlashloanCall
                "consumeAllowance(address,uint256)",
                weth,
                flashloanFee
            ),
            abi.encodeWithSignature( // bytes memory withFlashloanCall,
                "multicall(bytes[])",
                withFlashloanCalls
            ),
            abi.encodeWithSignature( // bytes memory postFlashloanCall
                "callExternal(address,bytes)",
                address(this),
                abi.encodeWithSignature(
                    "pullToken(uint256)",
                    50
                )
            )
        );

        // check token movements
        assertEq(ERC20Permit(weth).balanceOf(address(this)), 0);
        assertEq(ERC20Permit(weth).balanceOf(address(gw)), 0);
        assertEq(token.balanceOf(address(gw)), 123 - 50);
        assertEq(token.balanceOf(address(this)), 50);
    }

    function testAuraTokenUnwrap() public {
        address bpt = 0xd0EC47c54cA5e20aaAe4616c25C825c7f48D4069; // rETH/wETH BPT
        bytes32 poolId = 0xd0ec47c54ca5e20aaae4616c25c825c7f48d40690000000000000000000004ef;
        address auraToken = 0x17F061160A167d4303d5a6D32C2AC693AC87375b; // aurarETH/wETH BPT-vault
        address auraTokenHolder = 0xcE96fE7Eb7186E9F894DE7703B4DF8ea60E2dD77;
        uint256 auraTokenHolderBalance = MockERC20(auraToken).balanceOf(auraTokenHolder);

        address balancerVault = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;
        address aaveV3Pool = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
        address weth = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
        uint256 flashloanAmount = 0.001 ether;
        uint256 flashloanFee = flashloanAmount * 5 / 10_000;
        
        vm.prank(auraTokenHolder);
        MockERC20(auraToken).approve(address(gw), auraTokenHolderBalance);

        // Prepare the calls for the withFlashloanCall
        bytes[] memory withFlashloanCalls = new bytes[](5);
        // pull aura tokens to the gateway
        withFlashloanCalls[0] = abi.encodeWithSignature(
            "consumeAllowance(address,uint256)",
            auraToken,
            auraTokenHolderBalance
        );
        // [AURA] withdraw & unwrap aurarETH/wETH BPT-vault -> BPT
        withFlashloanCalls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            auraToken,
            abi.encodeWithSignature(
                "withdrawAndUnwrap(uint256,bool)",
                auraTokenHolderBalance,
                false
            )
        );
        // [BALANCER] withdraw BPT -> WETH
        withFlashloanCalls[2] = _getBalancerVaultWithdrawCallExternalData(
            balancerVault,
            weth,
            poolId,
            auraTokenHolderBalance // bptAmountIn
        );
        // check balance is enough to repay flashloan
        withFlashloanCalls[3] = abi.encodeWithSignature(
            "checkBalanceAtLeast(address,uint256)",
            weth,
            flashloanAmount + flashloanFee
        );
        // approve to repay flashloan
        withFlashloanCalls[4] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            weth,
            abi.encodeWithSignature(
                "approve(address,uint256)",
                aaveV3Pool,
                flashloanAmount + flashloanFee
            )
        );

        // Initiate the flashloan
        vm.prank(auraTokenHolder);
        gw.actionWithFlashLoan(
            aaveV3Pool, // address flashloanProvider
            abi.encodeWithSignature( // bytes memory initiateFlashloanCall
                "flashLoanSimple(address,address,uint256,bytes,uint16)",
                address(gw),
                weth,
                flashloanAmount,
                "",
                0 // referralCode, 0 for no referral
            ),
            "", // bytes memory preFlashloanCall
            abi.encodeWithSignature( // bytes memory withFlashloanCall
                "multicall(bytes[])",
                withFlashloanCalls
            ),
            "" // bytes memory postFlashloanCall
        );

        // Verify the results
        assertEq(MockERC20(auraToken).balanceOf(address(gw)), 0);
        assertEq(MockERC20(bpt).balanceOf(address(gw)), 0);
        assertGt(MockERC20(weth).balanceOf(address(gw)), auraTokenHolderBalance);
    }

    function _getBalancerVaultWithdrawCallExternalData(
        address balancerVault,
        address exitToken,
        bytes32 poolId,
        uint256 bptAmountIn
    ) internal returns (bytes memory) {
        // [BALANCER] withdraw BPT -> WETH
        (address[] memory poolTokens, , ) = IBalancerVault(balancerVault).getPoolTokens(poolId);
        uint256[] memory minAmountsOut = new uint256[](poolTokens.length);
        uint256 tokenIndex = 0;
        for (uint256 i = 0; i < minAmountsOut.length; i++) {
            if (poolTokens[i] == exitToken) {
                tokenIndex = i;
                minAmountsOut[i] = bptAmountIn * 995 / 1000;
            }
        }
        uint256 exitKind = 0; // EXACT_BPT_IN_FOR_ONE_TOKEN_OUT
        return abi.encodeWithSignature(
            "callExternal(address,bytes)",
            balancerVault,
            abi.encodeWithSignature(
                "exitPool(bytes32,address,address,(address[],uint256[],bytes,bool))",
                poolId,
                address(gw),
                address(gw),
                ExitPoolRequest({
                    tokens: poolTokens,
                    amounts: minAmountsOut,
                    data: abi.encodePacked(
                        exitKind, // ExitKind
                        bptAmountIn, // bptAmountIn
                        tokenIndex // exitTokenIndex
                    ),
                    toInternalBalance: false
                })
            )
        );
    }

    function _getPermitData(
        address tkn,
        uint256 amount,
        address to,
        address from,
        uint256 fromPrivateKey
    ) internal view returns (PermitData memory permitData) {
        uint256 deadline = block.timestamp + 100;
        // sign permit message valid for 10s
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                from,
                to,
                amount,
                ERC20Permit(tkn).nonces(from),
                deadline
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(
            ERC20Permit(tkn).DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPrivateKey, digest);

        return PermitData({v: v, r: r, s: s, deadline: deadline});
    }
}
