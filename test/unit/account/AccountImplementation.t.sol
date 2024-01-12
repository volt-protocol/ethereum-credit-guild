// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {AccountImplementation} from "@src/account/AccountImplementation.sol";
import {AccountFactory} from "@src/account/AccountFactory.sol";
import {MockERC20} from "../../mock/MockERC20.sol";
import {MockBalancerVault} from "../../mock/MockBalancerVault.sol";
import {MockExternalContract} from "../../mock/MockExternalContract.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver: rejecting ETH");
    }
}

error CallExternalError(bytes innerError);

/// @title Test suite for the AccountImplementation contract
/// @notice Implements various test cases to validate the functionality of AccountImplementation contract
contract UnitTestAccountImplementation is Test {
    /// @notice Contract instance of AccountFactory used in tests
    AccountFactory public factory;

    /// @notice Address used as factory owner in tests
    address factoryOwner = address(10101);

    /// @notice Address used to represent a typical user (Alice)
    address alice = address(1);
    /// @notice Address used to represent another user (Bob)
    address bob = address(2);

    /// @notice Signature for an allowed function call (ThisFunctionWillRevert(uint256)
    bytes4 allowedSig1 = bytes4(0xcfec160d);
    /// @notice Signature for an allowed function call (ThisFunctionIsOk(uint256)
    bytes4 allowedSig2 = bytes4(0x2af749ff);

    /// @notice Address of the valid implementation used in tests
    address validImplementation;
    /// @notice Instance of AccountImplementation for Alice
    AccountImplementation aliceAccount;
    /// @notice MockERC20 token instance used in tests
    MockERC20 mockToken;
    /// @notice Address used as an allowed target external calls
    address allowedTarget;

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

    /// @notice Sets up the test by deploying contracts and setting initial states
    function setUp() public {
        // set up a factory and an implementation
        vm.startPrank(factoryOwner);
        allowedTarget = address(new MockExternalContract());
        factory = new AccountFactory();
        validImplementation = address(new AccountImplementation());
        factory.allowImplementation(validImplementation, true);
        factory.allowCall(allowedTarget, allowedSig1, true);
        factory.allowCall(allowedTarget, allowedSig2, true);
        vm.stopPrank();

        // set up an account for alice
        vm.prank(alice);
        aliceAccount = AccountImplementation(
            factory.createAccount(validImplementation)
        );

        // set up a mockerc20
        mockToken = new MockERC20();
    }

    /// @notice Tests the initial state of contracts and variables
    function testInit() public {
        assertEq(factory.allowedCalls(allowedTarget, allowedSig1), true);
        assertEq(factory.allowedCalls(allowedTarget, allowedSig2), true);
        assertTrue(validImplementation != address(0));
        assertTrue(address(aliceAccount) != address(0));
        assertEq(alice, aliceAccount.owner());
    }

    /// @notice Tests that calling initialize on an already initialized account should fail
    function testCallInitializeShouldFail() public {
        vm.expectRevert("AccountImplementation: already initialized");
        aliceAccount.initialize(bob);
    }

    /// @notice Tests that a non-owner cannot renounce ownership
    function testRenounceOwnershipShouldFailIfNotOwner() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(bob);
        aliceAccount.renounceOwnership();
    }

    /// @notice Tests that even the owner cannot renounce ownership
    function testRenounceOwnershipShouldFailEvenifOwner() public {
        vm.expectRevert("AccountImplementation: cannot renounce ownership");
        vm.prank(alice);
        aliceAccount.renounceOwnership();
    }

    /// @notice Tests that non-owner cannot withdraw tokens
    function testWithdrawShouldFailIfNotOwner() public {
        mockToken.mint(address(aliceAccount), 1000e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 1000e18);

        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        aliceAccount.withdraw(address(mockToken), 1000e18);
    }

    /// @notice Tests that the owner can withdraw the specified amount of tokens
    function testWithdrawShouldWithdrawTheAmountRequested() public {
        mockToken.mint(address(aliceAccount), 1000e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 1000e18);
        assertEq(mockToken.balanceOf(alice), 0);

        vm.prank(alice);
        aliceAccount.withdraw(address(mockToken), 250e18);
        assertEq(mockToken.balanceOf(address(aliceAccount)), 750e18);
        assertEq(mockToken.balanceOf(alice), 250e18);
    }

    /// @notice Tests that non-owner cannot withdraw ETH
    function testWithdrawEthShouldFailIfNotOwner() public {
        // try to withdraw eth as bob
        vm.prank(bob);
        vm.expectRevert("Ownable: caller is not the owner");
        aliceAccount.withdrawEth();
    }

    /// @notice Tests that withdrawing ETH fails if the balance is zero
    function testWithdrawEthShouldFailIfNoBalance() public {
        vm.prank(alice);
        vm.expectRevert("AccountImplementation: no ETH to withdraw");
        aliceAccount.withdrawEth();
    }

    /// @notice Tests that ETH withdrawal fails if the call to send eth somehow fails
    function testWithdrawFailShouldRevert() public {
        RejectingReceiver receiver = new RejectingReceiver();
        vm.prank(address(receiver));
        address createdAccount = factory.createAccount(validImplementation);
        assertEq(createdAccount.balance, 0);
        assertEq(
            AccountImplementation(createdAccount).owner(),
            address(receiver)
        );

        vm.deal(createdAccount, 1e18);
        assertEq(createdAccount.balance, 1e18);

        vm.prank(address(receiver));
        vm.expectRevert("AccountImplementation: failed to send ETH");
        AccountImplementation(createdAccount).withdrawEth();
    }

    /// @notice Tests that the owner can withdraw ETH successfully
    function testWithdrawShouldWithdrawEth() public {
        assertEq(alice.balance, 0);

        // deal 1 eth to alice account
        assertEq(address(aliceAccount).balance, 0);
        vm.deal(address(aliceAccount), 1e18);
        assertEq(address(aliceAccount).balance, 1e18);

        vm.prank(alice);
        aliceAccount.withdrawEth();
        assertEq(alice.balance, 1e18);
    }

    /// @notice Confirms that external calls by non-owners are correctly rejected
    function testCallExternalShouldFailIfNotOwner() public {
        bytes memory data = bytes("0x01020304");

        vm.expectRevert("Not owner or initiated by owner");
        aliceAccount.callExternal(address(1), data);
    }

    /// @notice Ensures that calls to non-allowed targets are properly restricted
    function testCallExternalShouldFailOnNonAllowedTarget() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );

        vm.prank(alice);
        vm.expectRevert("AccountImplementation: cannot call target");
        aliceAccount.callExternal(address(1), data);
    }

    /// @notice Checks that calls with non-allowed signatures are prohibited
    function testCallExternalShouldFailOnNonAllowedSignature() public {
        bytes memory data = abi.encodeWithSignature(
            "nonAllowedFunction(uint256,string)",
            42,
            "Hello"
        );

        vm.prank(alice);
        vm.expectRevert("AccountImplementation: cannot call target");
        aliceAccount.callExternal(allowedTarget, data);
    }

    /// @notice Verifies that failing external calls revert as expected
    function testCallExternalFailingShouldRevert() public {
        bytes memory data = abi.encodeWithSignature(
            "ThisFunctionWillRevert(uint256)",
            uint256(1000)
        );

        vm.prank(alice);
        vm.expectRevert("I told you I would revert");
        aliceAccount.callExternal(allowedTarget, data);
    }

    /// @notice Tests that external calls without a revert message are handled correctly
    function testCallExternalFailingShouldRevertWithoutMsg() public {
        bytes memory data = abi.encodeWithSignature(
            "ThisFunctionWillRevertWithoutMsg(uint256)",
            uint256(1000)
        );
        bytes4 functionSelector = bytes4(
            keccak256("ThisFunctionWillRevertWithoutMsg(uint256)")
        );
        vm.prank(factoryOwner);
        // allow "ThisFunctionWillRevertWithoutMsg(uint256)"
        factory.allowCall(allowedTarget, functionSelector, true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(CallExternalError.selector, bytes(""))
        );

        aliceAccount.callExternal(allowedTarget, data);
    }

    /// @notice Confirms successful execution of allowed external calls
    function testCallExternalSuccessShouldWork() public {
        assertEq(0, MockExternalContract(allowedTarget).AmountSaved());

        bytes memory data = abi.encodeWithSignature(
            "ThisFunctionIsOk(uint256)",
            uint256(1000)
        );

        vm.prank(alice);
        aliceAccount.callExternal(allowedTarget, data);

        assertEq(1000, MockExternalContract(allowedTarget).AmountSaved());
    }

    /// @notice Validates that a multicall with at least one failing call fails as expected
    function testMulticallWithOneFailShouldFail() public {
        assertEq(0, MockExternalContract(allowedTarget).AmountSaved());

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(1000))
        );
        calls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature(
                "ThisFunctionWillRevert(uint256)",
                uint256(25000)
            )
        );

        vm.prank(alice);
        vm.expectRevert("I told you I would revert");
        aliceAccount.multicall(calls);
    }

    /// @notice Tests basic functionality of successful multicalls
    function testMulticallBasicSuccess() public {
        assertEq(0, MockExternalContract(allowedTarget).AmountSaved());

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(1000))
        );
        calls[1] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(25000))
        );

        vm.prank(alice);
        aliceAccount.multicall(calls);
        assertEq(25000, MockExternalContract(allowedTarget).AmountSaved());
    }

    /// @notice Prepares and verifies deployment of a mock Balancer vault for testing
    /// this deploy the mock and set etch the bytecode to the real BALANCER_VAULT address
    function prepareBalancerVault() public {
        address mockAddress = address(new MockBalancerVault());
        bytes memory code = getCode(mockAddress);
        vm.etch(aliceAccount.BALANCER_VAULT(), code);

        // test that the contract is deployed at the good address
        MockBalancerVault balancerVault = MockBalancerVault(
            aliceAccount.BALANCER_VAULT()
        );
        assertEq("I am MockBalancerVault", balancerVault.WhoAmI());
    }

    /// @notice Conducts a test scenario involving a Balancer flash loan
    /// this test shows that the balancer send the tokens and then that the calls are performed
    /// in a multicall way, and that we give the tokens back to the flashloan
    function testBalancerFlashLoan() public {
        // first deploy the mock balancer vault and set it at the correct address
        prepareBalancerVault();

        // we will deal 1000 token to the vault
        mockToken.mint(aliceAccount.BALANCER_VAULT(), 1000);
        assertEq(mockToken.balanceOf(aliceAccount.BALANCER_VAULT()), 1000);

        // setup calls
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(mockToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 750;
        bytes[] memory preCalls = new bytes[](1);
        preCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(1000))
        );
        bytes[] memory postCalls = new bytes[](1);
        postCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(750))
        );

        vm.prank(alice);
        aliceAccount.multicallWithBalancerFlashLoan(
            tokens,
            amounts,
            preCalls,
            postCalls
        );
        assertEq(750, MockExternalContract(allowedTarget).AmountSaved());
    }

    /// @notice Conducts a test scenario involving a Balancer flash loan where we don't have enough token reimburse the loan
    function testBalancerFlashLoanFailToReimburse() public {
        // first deploy the mock balancer vault and set it at the correct address
        prepareBalancerVault();

        // we will deal 1000 token to the vault
        mockToken.mint(aliceAccount.BALANCER_VAULT(), 1000);
        assertEq(mockToken.balanceOf(aliceAccount.BALANCER_VAULT()), 1000);

        // whitelist a call to the mockToken for the transfer function
        bytes4 functionSelector = bytes4(
            keccak256("transfer(address,uint256)")
        );
        vm.prank(factoryOwner);
        factory.allowCall(address(mockToken), functionSelector, true);

        // setup calls
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(mockToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 750;
        bytes[] memory preCalls = new bytes[](1);
        preCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            allowedTarget,
            abi.encodeWithSignature("ThisFunctionIsOk(uint256)", uint256(1000))
        );
        bytes[] memory postCalls = new bytes[](1);

        // this sends bob 100 token from the flash loan
        postCalls[0] = abi.encodeWithSignature(
            "callExternal(address,bytes)",
            address(mockToken),
            abi.encodeWithSignature(
                "transfer(address,uint256)",
                bob,
                uint256(100)
            )
        );

        vm.prank(alice);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        aliceAccount.multicallWithBalancerFlashLoan(
            tokens,
            amounts,
            preCalls,
            postCalls
        );
    }

    /// @notice Ensures that unauthorized addresses cannot call the receiveFlashLoan function
    function testNonBalancerVaultCannotCallReceiveFlashLoan() public {
        IERC20[] memory tokens = new IERC20[](1);
        tokens[0] = IERC20(mockToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 750;
        uint256[] memory feeAmounts = new uint256[](1);
        amounts[0] = 150;

        vm.prank(bob);
        vm.expectRevert("receiveFlashLoan: sender is not balancer");
        aliceAccount.receiveFlashLoan(tokens, amounts, feeAmounts, "");
    }
}
