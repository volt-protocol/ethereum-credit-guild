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
import {RateLimitedCreditMinter} from "@src/rate-limits/RateLimitedCreditMinter.sol";

contract LendingTermSignaturesUnitTest is Test {
    address private governor = address(1);
    address private guardian = address(2);
    Core private core;
    CreditToken credit;
    GuildToken guild;
    MockERC20 collateral;
    RateLimitedCreditMinter rlcm;
    AuctionHouse auctionHouse;
    LendingTerm term;

    uint256 public alicePrivateKey = uint256(0x42);
    address public alice = vm.addr(alicePrivateKey);
    uint256 public bobPrivateKey = uint256(0x43);
    address public bob = vm.addr(bobPrivateKey);

    // GUILD params
    uint32 constant _CYCLE_LENGTH = 1 hours;
    uint32 constant _FREEZE_PERIOD = 10 minutes;

    // LendingTerm params
    uint256 constant _CREDIT_PER_COLLATERAL_TOKEN = 2000e18; // 2000, same decimals
    uint256 constant _INTEREST_RATE = 0.10e18; // 10% APR
    uint256 constant _CALL_FEE = 0.05e18; // 5%
    uint256 constant _CALL_PERIOD = 1 hours;
    uint256 constant _HARDCAP = 20_000_000e18;
    uint256 constant _LTV_BUFFER = 0.20e18; // 20%

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        core = new Core();

        collateral = new MockERC20();
        credit = new CreditToken(address(core));
        guild = new GuildToken(address(core), address(credit), _CYCLE_LENGTH, _FREEZE_PERIOD);
        rlcm = new RateLimitedCreditMinter(
            address(core), /*_core*/
            address(credit), /*_token*/
            type(uint256).max, /*_maxRateLimitPerSecond*/
            type(uint128).max, /*_rateLimitPerSecond*/
            type(uint128).max /*_bufferCap*/
        );
        auctionHouse = new AuctionHouse(
            address(core),
            address(guild),
            address(rlcm),
            address(credit)
        );
        term = new LendingTerm(
            address(core), /*_core*/
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
                openingFee: 0,
                callFee: _CALL_FEE,
                callPeriod: _CALL_PERIOD,
                hardCap: _HARDCAP,
                ltvBuffer: _LTV_BUFFER
            })
        );

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
        guild.addGauge(address(term));
        guild.mint(address(this), _HARDCAP * 2);
        guild.incrementGauge(address(term), uint112(_HARDCAP));

        // labels
        vm.label(address(core), "core");
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
        assertEq(term.DOMAIN_SEPARATOR(), keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Ethereum Credit Guild")),
                keccak256(bytes("1")),
                block.chainid,
                address(term)
            )
        ));
        assertEq(term.nonces(alice), 0);
        assertEq(term.nonces(bob), 0);
    }

    function testBorrowBySig() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);

        // manual approve
        vm.prank(alice);
        collateral.approve(address(term), collateralAmount);

        // sign borrow message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            term._BORROW_TYPEHASH(),
            address(term),
            alice,
            borrowAmount,
            collateralAmount,
            term.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.borrowBySig(
            alice,
            borrowAmount,
            collateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // borrow
        bytes32 loanId = term.borrowBySig(
            alice,
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
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.borrowBySig(
            alice,
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
    }

    function testBorrowWithPermit() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);

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

    function testBorrowBySigWithPermit() public {
        // prepare
        uint256 borrowAmount = 20_000e18;
        uint256 collateralAmount = 12e18;
        collateral.mint(alice, collateralAmount);

        // sign borrow message valid for 10s
        LendingTerm.Signature memory borrowSig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._BORROW_TYPEHASH(),
                address(term),
                alice,
                borrowAmount,
                collateralAmount,
                term.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            borrowSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // sign permit message valid for 10s
        LendingTerm.Signature memory permitSig;
        {
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
            permitSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        vm.prank(alice);
        term.borrowBySigWithPermit(
            alice,
            borrowAmount,
            collateralAmount,
            block.timestamp - 10,
            borrowSig,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // borrow
        bytes32 loanId = term.borrowBySigWithPermit(
            alice,
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            borrowSig,
            permitSig
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
        assertEq(term.nonces(alice), 1);
        assertEq(collateral.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        vm.prank(alice);
        term.borrowBySigWithPermit(
            alice,
            borrowAmount,
            collateralAmount,
            block.timestamp + 10,
            borrowSig,
            permitSig
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
        vm.prank(alice);
        bytes32 loanId = term.borrow(
            borrowAmount,
            collateralAmount
        );

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 13);

        return loanId;
    }

    function testAddCollateralBySig() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 addCollateralAmount = 10e18;
        collateral.mint(alice, addCollateralAmount);

        // manual approve
        vm.prank(alice);
        collateral.approve(address(term), addCollateralAmount);

        // sign addCollateral message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            term._ADD_COLLATERAL_TYPEHASH(),
            address(term),
            alice,
            loanId,
            addCollateralAmount,
            term.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.addCollateralBySig(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // add collateral
        term.addCollateralBySig(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan updated
        assertEq(term.getLoan(loanId).collateralAmount, 12e18 + addCollateralAmount);

        // nonce is consumed, cannot broadcast again
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.addCollateralBySig(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
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

    function testAddCollateralBySigWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 addCollateralAmount = 10e18;
        collateral.mint(alice, addCollateralAmount);

        // sign addCollateral message valid for 10s
        LendingTerm.Signature memory addCollateralSig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._ADD_COLLATERAL_TYPEHASH(),
                address(term),
                alice,
                loanId,
                addCollateralAmount,
                term.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            addCollateralSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // sign permit message valid for 10s
        LendingTerm.Signature memory permitSig;
        {
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
            permitSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.addCollateralBySigWithPermit(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp - 10,
            addCollateralSig,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // addCollateral
        term.addCollateralBySigWithPermit(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            addCollateralSig,
            permitSig
        );

        // check loan updated
        assertEq(term.getLoan(loanId).collateralAmount, 12e18 + addCollateralAmount);

        // nonce is consumed, cannot broadcast again
        assertEq(collateral.nonces(alice), 1);
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.addCollateralBySigWithPermit(
            alice,
            loanId,
            addCollateralAmount,
            block.timestamp + 10,
            addCollateralSig,
            permitSig
        );
    }

    function testPartialRepayBySig() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 debtToRepay = 5_000e18;
        credit.mint(alice, debtToRepay);
        vm.prank(alice);
        credit.approve(address(term), debtToRepay); // manual appove

        // sign partialRepay message valid for 10s
        LendingTerm.Signature memory partialRepaySig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._PARTIAL_REPAY_TYPEHASH(),
                address(term),
                alice,
                loanId,
                debtToRepay,
                term.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            partialRepaySig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.partialRepayBySig(
            alice,
            loanId,
            debtToRepay,
            block.timestamp - 10,
            partialRepaySig
        );
        vm.warp(block.timestamp - 20);

        // partialRepay
        uint256 debtBefore = term.getLoanDebt(loanId);
        term.partialRepayBySig(
            alice,
            loanId,
            debtToRepay,
            block.timestamp + 10,
            partialRepaySig
        );

        // check loan updated +- 0.01% error due to rounding
        assertGt(term.getLoanDebt(loanId), debtBefore - debtToRepay - 0.0001e18);
        assertLt(term.getLoanDebt(loanId), debtBefore - debtToRepay + 0.0001e18);

        // nonce is consumed, cannot broadcast again
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.partialRepayBySig(
            alice,
            loanId,
            debtToRepay,
            block.timestamp + 10,
            partialRepaySig
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

    function testPartialRepayBySigWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        // prepare
        uint256 debtToRepay = 5_000e18;
        credit.mint(alice, debtToRepay);

        // sign partialRepay message valid for 10s
        LendingTerm.Signature memory partialRepaySig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._PARTIAL_REPAY_TYPEHASH(),
                address(term),
                alice,
                loanId,
                debtToRepay,
                term.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            partialRepaySig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

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
        vm.expectRevert("LendingTerm: expired deadline");
        term.partialRepayBySigWithPermit(
            alice,
            loanId,
            debtToRepay,
            block.timestamp - 10,
            partialRepaySig,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // partialRepay
        uint256 debtBefore = term.getLoanDebt(loanId);
        term.partialRepayBySigWithPermit(
            alice,
            loanId,
            debtToRepay,
            block.timestamp + 10,
            partialRepaySig,
            permitSig
        );

        // check loan updated +- 0.01% error due to rounding
        assertGt(term.getLoanDebt(loanId), debtBefore - debtToRepay - 0.0001e18);
        assertLt(term.getLoanDebt(loanId), debtBefore - debtToRepay + 0.0001e18);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.partialRepayBySigWithPermit(
            alice,
            loanId,
            debtToRepay,
            block.timestamp + 10,
            partialRepaySig,
            permitSig
        );
    }

    function testRepayBySig() public {
        bytes32 loanId = _doAliceBorrow();

        // manual approve
        credit.mint(alice, 1_000e18); // mint enough to cover interests
        vm.prank(alice);
        credit.approve(address(term), 21_000e18);

        // sign repay message valid for 10s
        bytes32 structHash = keccak256(abi.encode(
            term._REPAY_TYPEHASH(),
            address(term),
            alice,
            loanId,
            term.nonces(alice),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), alice);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.repayBySig(
            alice,
            loanId,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // repay
        term.repayBySig(
            alice,
            loanId,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.repayBySig(
            alice,
            loanId,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
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

    function testRepayBySigWithPermit() public {
        bytes32 loanId = _doAliceBorrow();

        credit.mint(alice, 1_000e18); // mint enough to cover interests

        // sign repay message valid for 10s
        LendingTerm.Signature memory repaySig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._REPAY_TYPEHASH(),
                address(term),
                alice,
                loanId,
                term.nonces(alice),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), alice);
            repaySig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // sign permit message valid for 10s
        LendingTerm.Signature memory permitSig;
        {
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
            permitSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.repayBySigWithPermit(
            alice,
            loanId,
            21_000e18,
            block.timestamp - 10,
            repaySig,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // repay
        uint256 debt = term.getLoanDebt(loanId);
        term.repayBySigWithPermit(
            alice,
            loanId,
            21_000e18,
            block.timestamp + 10,
            repaySig,
            permitSig
        );

        // check loan is closed
        assertEq(term.getLoan(loanId).closeTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(credit.nonces(alice), 1);
        assertEq(term.nonces(alice), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.repayBySigWithPermit(
            alice,
            loanId,
            21_000e18,
            block.timestamp + 10,
            repaySig,
            permitSig
        );

        // check not all credit is pulled but just the debt amount
        assertEq(credit.balanceOf(alice), 21_000e18 - debt);
    }

    function testCallManyBySig() public {
        bytes32 loanId = _doAliceBorrow();

        // manual approve
        credit.mint(bob, 1_000e18); // mint enough to cover call fee
        vm.prank(bob);
        credit.approve(address(term), 1_000e18);

        // sign call message valid for 10s
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;
        bytes32 structHash = keccak256(abi.encode(
            term._CALL_TYPEHASH(),
            address(term),
            bob,
            keccak256(abi.encodePacked(loanIds)),
            term.nonces(bob),
            block.timestamp + 10
        ));
        bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
        assertEq(ECDSA.recover(digest, v, r, s), bob);

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.callManyBySig(
            bob,
            loanIds,
            block.timestamp - 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
        vm.warp(block.timestamp - 20);

        // call
        term.callManyBySig(
            bob,
            loanIds,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );

        // check loan is called
        assertEq(term.getLoan(loanId).caller, bob);
        assertEq(term.getLoan(loanId).callTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(term.nonces(bob), 1);
        vm.expectRevert("LendingTerm: invalid signature");
        term.callManyBySig(
            bob,
            loanIds,
            block.timestamp + 10,
            LendingTerm.Signature({ v: v, r: r, s: s })
        );
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

    function testCallManyBySigWithPermit() public {
        bytes32 loanId = _doAliceBorrow();
        bytes32[] memory loanIds = new bytes32[](1);
        loanIds[0] = loanId;

        // mint enough to cover call fee
        credit.mint(bob, 1_000e18); 

        // sign call message valid for 10s
        LendingTerm.Signature memory callSig;
        {
            bytes32 structHash = keccak256(abi.encode(
                term._CALL_TYPEHASH(),
                address(term),
                bob,
                keccak256(abi.encodePacked(loanIds)),
                term.nonces(bob),
                block.timestamp + 10
            ));
            bytes32 digest = ECDSA.toTypedDataHash(term.DOMAIN_SEPARATOR(), structHash);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(bobPrivateKey, digest);
            assertEq(ECDSA.recover(digest, v, r, s), bob);
            callSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // sign permit message valid for 10s
        LendingTerm.Signature memory permitSig;
        {
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
            permitSig = LendingTerm.Signature({ v: v, r: r, s: s });
        }

        // if deadline is passed, cannot broadcast
        vm.warp(block.timestamp + 20);
        vm.expectRevert("LendingTerm: expired deadline");
        term.callManyBySigWithPermit(
            bob,
            loanIds,
            block.timestamp - 10,
            callSig,
            permitSig
        );
        vm.warp(block.timestamp - 20);

        // call
        term.callManyBySigWithPermit(
            bob,
            loanIds,
            block.timestamp + 10,
            callSig,
            permitSig
        );

        // check loan is called
        assertEq(term.getLoan(loanId).caller, bob);
        assertEq(term.getLoan(loanId).callTime, block.timestamp);

        // nonce is consumed, cannot broadcast again
        assertEq(term.nonces(bob), 1);
        assertEq(credit.nonces(bob), 1);
    }
}
