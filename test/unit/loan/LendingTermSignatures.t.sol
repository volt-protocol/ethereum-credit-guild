// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {Core} from "@src/core/Core.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {CoreRoles} from "@src/core/CoreRoles.sol";
import {MockERC20} from "@test/mock/MockERC20.sol";
import {GuildToken} from "@src/tokens/GuildToken.sol";
import {CreditToken} from "@src/tokens/CreditToken.sol";
import {LendingTerm} from "@src/loan/LendingTerm.sol";
import {AuctionHouse} from "@src/loan/AuctionHouse.sol";
import {ProfitManager} from "@src/governance/ProfitManager.sol";
import {RateLimitedMinter} from "@src/rate-limits/RateLimitedMinter.sol";

contract LendingTermSignaturesUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    ProfitManager private profitManager;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    RateLimitedMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);
    uint256 public bobPrivateKey = uint256(0x43);
    address public bob = vm.addr(bobPrivateKey);

    // LendingTerm params
    uint256 constant _CREDIT_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals
    uint256 constant _INTEREST_RATE = 0.10e18; // 10% APR
    uint256 constant _OPENING_FEE = 0.02e18; // 2%
    uint256 constant _CALL_FEE = 0.05e18; // 5%
    uint256 constant _CALL_PERIOD = 1 hours;
    uint256 constant _HARDCAP = 20_000_000e18;
    uint256 constant _LTV_BUFFER = 0.20e18; // 20%

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        profitManager = new ProfitManager(address(core));
        collateral = new MockERC20();
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(profitManager), address(credit));
        rlcm = new RateLimitedMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            CoreRoles.RATE_LIMITED_CREDIT_MINTER, /*_role*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(
            address(core),
            650,
            1800,
            0.1e18
        );
        term = new LendingTerm(
            address(core), /*_core*/
            address(profitManager), /*_profitManager*/
            address(guild), /*_guildToken*/
            address(auctionHouse), /*_auctionHouse*/
            address(rlcm), /*_creditMinter*/
            address(credit), /*_creditToken*/
            LendingTerm.LendingTermParams({
                collateralToken: address(collateral),
                maxDebtPerCollateralToken: _CREDIT_PER_COLLATERAL_TOKEN,
                interestRate: _INTEREST_RATE,
                maxDelayBetweenPartialRepay: 0,
                minPartialRepayPercent: 0,
                openingFee: _OPENING_FEE,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );
        profitManager.initializeReferences(address(credit), address(guild));

        // roles
        core.grantRole(CoreRoles.GOVERNOR, governor);
        core.grantRole(CoreRoles.GUARDIAN, guardian);
        core.grantRole(CoreRoles.CREDIT_MINTER, address(this));
        core.grantRole(CoreRoles.GUILD_MINTER, address(this));
        core.grantRole(CoreRoles.GAUGE_ADD, address(this));
        core.grantRole(CoreRoles.GAUGE_REMOVE, address(this));
        core.grantRole(CoreRoles.GAUGE_PARAMETERS, address(this));
        core.grantRole(CoreRoles.CREDIT_MINTER, address(rlcm));
        core.grantRole(CoreRoles.RATE_LIMITED_CREDIT_MINTER, address(term));
        core.grantRole(CoreRoles.GAUGE_PNL_NOTIFIER, address(term));
        core.renounceRole(CoreRoles.GOVERNOR, address(this));

        // add gauge and vote for it
        guild.setMaxGauges(10);
        guild.addGauge(1, address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), _HARDCAP);

        // labels
        vm.label(address(core), "core");
        vm.label(address(profitManager), "profitManager");
        vm.label(address(collateral), "collateral");
        vm.label(address(credit), "credit");
        vm.label(address(guild), "guild");
        vm.label(address(rlcm), "rlcm");
        vm.label(address(auctionHouse), "auctionHouse");
        vm.label(address(term), "term");
        vm.label(alice, "alice");
        vm.label(bob, "bob");
    }

    function testInitialState() public {
        assertEq(term.interestRate(), _INTEREST_RATE);
    }

    function testBorrowWithPermit() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);
        credit.mint(alice, 400e18);
        vm.prank(alice);
        credit.approve(address(term), 400e18);

        // sign permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            collateralAmount,
            collateral.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(collateral.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.borrowWithPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // borrow
        vm.prank(alice);
        bytes32 loanId = term.borrowWithPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan creation
        assertEq(term.getLoan(loanId).borrower, alice);
        assertEq(term.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, 0);

        // nonce is consumed, cannot broadcast again
        assertEq(collateral.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.borrowWithPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
    }

    function testBorrowWithCreditPermit() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);
        credit.mint(alice, 400e18);
        vm.prank(alice);
        collateral.approve(address(term), collateralAmount);

        // sign permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            400e18,
            credit.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(credit.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.borrowWithCreditPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // borrow
        vm.prank(alice);
        bytes32 loanId = term.borrowWithCreditPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan creation
        assertEq(term.getLoan(loanId).borrower, alice);
        assertEq(term.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, 0);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.borrowWithCreditPermit(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
    }

    function testBorrowWithPermits() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);
        credit.mint(alice, 400e18);

        // sign credit permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            400e18,
            credit.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(credit.DOMAIN_SEPARATOR(), structHash);
        (uint8 vCredit, bytes32 rCredit, bytes32 sCredit) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, vCredit, rCredit, sCredit), alice);

        // sign collateral permit message valid for 10s
        structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            collateralAmount,
            collateral.nonces(alice),
            block.timestamp + 10
        ));
        digest = ECDSA.toTypedDataHash(collateral.DOMAIN_SEPARATOR(), structHash);
        (uint8 vCollateral, bytes32 rCollateral, bytes32 sCollateral) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, vCollateral, rCollateral, sCollateral), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.borrowWithPermits(
            borrowAmount,
            collateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: vCollateral, r: rCollateral, s: sCollateral }),
            LendingTerm.Signature({ v: vCredit, r: rCredit, s: sCredit })
        );
        vm.warp(block.timestamp - 20);

        // borrow
        vm.prank(alice);
        bytes32 loanId = term.borrowWithPermits(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: vCollateral, r: rCollateral, s: sCollateral }),
            LendingTerm.Signature({ v: vCredit, r: rCredit, s: sCredit })
        );

        // check loan creation
        assertEq(term.getLoan(loanId).borrower, alice);
        assertEq(term.getLoan(loanId).borrowAmount, borrowAmount);
        assertEq(term.getLoan(loanId).collateralAmount, collateralAmount);
        assertEq(term.getLoan(loanId).caller, address(0));
        assertEq(term.getLoan(loanId).callTime, 0);
        assertEq(term.getLoan(loanId).originationTime, block.timestamp);
        assertEq(term.getLoan(loanId).closeTime, 0);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        assertEq(collateral.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.borrowWithPermits(
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: vCollateral, r: rCollateral, s: sCollateral }),
            LendingTerm.Signature({ v: vCredit, r: rCredit, s: sCredit })
        );
    }

    function _doAliceBorrow() internal returns (bytes32) {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);

        // manual approve
        vm.prank(alice);
        collateral.approve(address(term), collateralAmount);

        // borrow
        credit.mint(alice, 400e18);
        vm.prank(alice);
        credit.approve(address(term), 400e18);
        vm.prank(alice);
        bytes32 loanId = term.borrow(
            borrowAmount,
            collateralAmount
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        return loanId;
    }

    function testAddCollateralWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 addCollateralAmount = 10e18;
        collateral.mint(alice, addCollateralAmount);

        // sign permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            addCollateralAmount,
            collateral.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(collateral.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.addCollateralWithPermit(
            loanId,
            addCollateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // addCollateral
        vm.prank(alice);
        term.addCollateralWithPermit(
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan updated
        assertEq(term.getLoan(loanId).collateralAmount, 12e18 + addCollateralAmount);

        // nonce is consumed, cannot broadcast again
        assertEq(collateral.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.addCollateralWithPermit(
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
    }

    function testPartialRepayWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 debtToRepay = 5_000e18;
        credit.mint(alice, debtToRepay);

        // sign permit message valid for 10s
        LendingTerm.Signature memory permitSig;
        {
            bytes32 structHash = keccak256(abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                alice,
                address(term),
                debtToRepay,
                credit.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(credit.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            permitSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.partialRepayWithPermit(
            loanId,
            debtToRepay,
            block.timestamp - 10,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // partialRepay
        uint256 debtBefore = term.getLoanDebt(loanId);
        vm.prank(alice);
        term.partialRepayWithPermit(
            loanId,
            debtToRepay,
            block.timestamp + 10,
            permitSig
        );

        // check loan updated +- 0.01% error due to rounding
        assertGt(term.getLoanDebt(loanId), debtBefore - debtToRepay - 0.0001e18);
        assertLt(term.getLoanDebt(loanId), debtBefore - debtToRepay + 0.0001e18);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.partialRepayWithPermit(
            loanId,
            debtToRepay,
            block.timestamp + 10,
            permitSig
        );
    }

    function testRepayWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        credit.mint(alice, 1_000e18); // mint enough to cover interests

        // sign permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            alice,
            address(term),
            21_000e18,
            credit.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(credit.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(alice);
        term.repayWithPermit(
            loanId,
            21_000e18,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // repay
        uint256 debt = term.getLoanDebt(loanId);
        vm.prank(alice);
        term.repayWithPermit(
            loanId,
            21_000e18,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        vm.expectRevert("ERC20Permit: invalid signature");
        vm.prank(alice);
        term.repayWithPermit(
            loanId,
            21_000e18,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check not all credit is pulled but just the debt amount
        assertEq(credit.balanceOf(alice), 21_000e18 - debt);
    }

    function testCallManyWithPermit() public {
        bytes32 loanId = _doAliceBorrow();
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;

        // mint enough to cover call fee
        credit.mint(bob, 1_000e18); 

        // sign permit message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
            bob,
            address(term),
            1_000e18,
            credit.nonces(bob),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(credit.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), bob);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("ERC20Permit: expired deadline");
        vm.prank(bob);
        term.callManyWithPermit(
            loanIds,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // call
        vm.prank(bob);
        term.callManyWithPermit(
            loanIds,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan is called
        assertEq(term.getLoan(loanId).caller, bob);
        assertEq(term.getLoan(loanId).callTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(bob), 1);
    }
}
