// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {ECGTest} from "@test/ECGTest.sol";

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

import {Core} from "@src/core/Core.sol";
import {Gateway} from "@src/gateway/Gateway.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {GatewayV1NoACL} from "@src/gateway/GatewayV1NoACL.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {SimplePSM} from "@src/loan/SimplePSM.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {MockBalancerVault} from "@test/mock/MockBalancerVault.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

struct PermitData {
    uint8 v;
    bytes32 r;
    bytes32 s;
    uint256 deadline;
}

/// @title Test suite for the GatewayV1 contract
contract UnitTestGatewayV1NoACL is ECGTest {
    // test users
    address private governor = address(9999999);
    address private guardian = address(8888888);
    address gatewayOwner = address(10101);
    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);
    address bob = address(0xb0bb0b);

    GatewayV1NoACL public gatewayv1;
    Core private core;
    ProfitManager public profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    MockERC20 pegtoken;
    SimplePSM private psm;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    /// @notice Retrieves the bytecode of a contract at a specific address for testing purposes
    function getCode(address _addr) public view returns (bytes memory) {
        bytes memory code;
        assembly {
            // Get the size of the code at address `_addr`
            let size := extcodesize(_addr)
            // Allocate memory for the code
            code := mload(0x40)
            // Update the free memory pointer
            mstore(0x40, add(code, and(add(add(size, 0x20), 0x1f), not(0x1f))))
            // Store the size in memory
            mstore(code, size)
            // Copy the code to memory
            extcodecopy(_addr, add(code, 0x20), 0, size)
        }
        return code;
    }

    // dummy functions to be called by the gateway
    uint256 public amountSaved;

    function successfulFunction(uint256 amount) public {
        amountSaved = amount;
    }

    function revertingFunction(uint256 /*amount*/) public pure {
        revert("I told you I would revert");
    }

    // mock uniswap router behavior
    function getAmountsIn(
        uint256 amountOut,
        address[] calldata /* path*/
    ) external pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountOut;
        amounts[1] = amountOut;
        return amounts;
    }

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata /* path*/
    ) external pure returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = amountIn;
        amounts[1] = amountIn;
        return amounts;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 /* amountOutMin*/,
        address[] calldata path,
        address to,
        uint256 /* deadline*/
    ) external returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        IERC20(path[1]).transfer(to, amountIn);
        return amounts;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 /* amountInMax*/,
        address[] calldata path,
        address to,
        uint256 /* deadline*/
    ) external returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountOut);
        IERC20(path[1]).transfer(to, amountOut);
        return amounts;
    }

    /// @notice Sets up the test by deploying the AccountFactory contract
    function setUp() public {
        vm.prank(gatewayOwner);
        gatewayv1 = new GatewayV1NoACL();

        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        pegtoken = new MockERC20();
        credit = new CreditToken(address(core), "name", "symbol");
        guild = new GuildToken(address(core));
        rlcm = new RateLimitedMinter(
            address(core) /*_core*/,
            address(credit) /*_token*/,
            CoreRoles.RATE_LIMITED_CREDIT_MINTER /*_role*/,
            type(uint256).max /*_maxRateLimitPerSecond*/,
            type(uint128).max /*_rateLimitPerSecond*/,
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(address(core), 650, 1800, 0);
        term = LendingTerm(Clones.clone(address(new LendingTerm())));
        term.initialize(
            address(core),
            LendingTerm.LendingTermReferences({
                profitManager: address(profitManager),
                guildToken: address(guild),
                auctionHouse: address(auctionHouse),
                creditMinter: address(rlcm),
                creditToken: address(credit)
            }),
            abi.encode(
                LendingTerm.LendingTermParams({
                    collateralToken: address(collateral),
                    maxDebtPerCollateralToken: 1e18,
                    interestRate: 0.05e18,
                    maxDelayBetweenPartialRepay: 0,
                    minPartialRepayPercent: 0,
                    openingFee: 0,
                    hardCap: 1e27
                })
            )
        );
        psm = new SimplePSM(
            address(core),
            address(profitManager),
            address(credit),
            address(pegtoken)
        );
        profitManager.initializeReferences(address(credit), address(guild));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(psm));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(term));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(profitManager));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(psm));
        core.grantRole(CoreRoles.CREDIT_BURNER, address(this));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), 1e18);
        guild.incrementGauge(address(term), 1e18);

        // large psm mint
        pegtoken.mint(address(this), 1e27);
        pegtoken.approve(address(psm), 1e27);
        psm.mint(address(this), 1e27);
        credit.enterRebase();

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(pegtoken), "pegtoken");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(address(this), "test");
        vm.label(address(gatewayv1), "gatewayV1");

        // deal tokens to the "vault" & "uniswap"
        collateral.mint(gatewayv1.balancerVault(), 1e27);
        pegtoken.mint(gatewayv1.balancerVault(), 1e27);
        collateral.mint(address(this), 1e27);
        pegtoken.mint(address(this), 1e27);
    }

    function getSelector(bytes memory f) public pure returns (bytes4) {
        return bytes4(keccak256(f));
    }

    function getPermitData(
        ERC20Permit token,
        uint256 amount,
        address to,
        address from,
        uint256 fromPrivateKey
    ) public view returns (PermitData memory permitData) {
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
                token.nonces(from),
                deadline
            )
        );

        bytes32 digest = ECDSA.toTypedDataHash(
            token.DOMAIN_SEPARATOR(),
            structHash
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(fromPrivateKey, digest);

        return PermitData({v: v, r: r, s: s, deadline: deadline});
    }

    
    function _singleCallExternal(address target, bytes memory data) internal {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            target,
            data
        );
        gatewayv1.multicall(calls);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testAllowCallCannotWork() public {
        
        vm.prank(gatewayOwner);
        vm.expectRevert("GatewayV1NoACL: unused function");
        gatewayv1.allowCall(address(1),bytes4(keccak256("randomFunction(uint256)")), true);
    }

    /// @notice Verifies that failing external calls revert as expected
    function testCallExternalFailingShouldRevert() public {
        bytes memory data = abi.encodeWithSignature(
            "revertingFunction(uint256)",
            uint256(1000)
        );
        vm.expectRevert("I told you I would revert");
        _singleCallExternal(address(this), data);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testCallExternalShouldWork() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );
        _singleCallExternal(address(1), data);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testTransferFromShouldNotWork() public {
        bytes memory data = abi.encodeWithSignature(
            "transferFrom(address,address,uint256)",
            address(1),
            address(2),
            1e18
        );

        vm.expectRevert("GatewayV1NoACL: cannot call transferFrom");
        _singleCallExternal(address(1), data);
    }
    
}
