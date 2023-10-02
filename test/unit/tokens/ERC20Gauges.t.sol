// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.13;

import {Test} from "@forge-std/Test.sol";
import {MockERC20Gauges} from "@test/mock/MockERC20Gauges.sol";

contract ERC20GaugesUnitTest is Test {
    MockERC20Gauges token;
    address constant gauge1 = address(0xDEAD);
    address constant gauge2 = address(0xBEEF);
    address constant gauge3 = address(0xF000);

    function setUp() public {
        vm.warp(1679067867);
        vm.roll(16848497);
        token = new MockERC20Gauges();
    }

    /*///////////////////////////////////////////////////////////////
                        TEST INITIAL STATE
    //////////////////////////////////////////////////////////////*/

    function testInitialState() public {
        assertEq(token.getUserGaugeWeight(address(this), gauge1), 0);
        assertEq(token.getUserGaugeWeight(address(this), gauge2), 0);
        assertEq(token.getUserWeight(address(this)), 0);
        assertEq(token.getGaugeWeight(gauge1), 0);
        assertEq(token.getGaugeWeight(gauge2), 0);
        assertEq(token.totalWeight(), 0);
        assertEq(token.gauges().length, 0);
        assertEq(token.isGauge(gauge1), false);
        assertEq(token.isGauge(gauge2), false);
        assertEq(token.numGauges(), 0);
        assertEq(token.deprecatedGauges().length, 0);
        assertEq(token.numDeprecatedGauges(), 0);
        assertEq(token.userGauges(address(this)).length, 0);
        assertEq(token.isUserGauge(address(this), gauge1), false);
        assertEq(token.isUserGauge(address(this), gauge2), false);
    }

    /*///////////////////////////////////////////////////////////////
                        TEST ADMIN GAUGE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function testSetMaxGauges(uint256 max) public {
        token.setMaxGauges(max);
        require(token.maxGauges() == max);
    }

    function testSetCanExceedMaxGauges() public {
        token.setCanExceedMaxGauges(address(this), true);
        require(token.canExceedMaxGauges(address(this)));

        // revert for non-smart contracts
        vm.expectRevert("ERC20Gauges: not a smart contract");
        token.setCanExceedMaxGauges(address(0xBEEF), true);
    }

    function testAddGauge(address[8] memory gauges) public {
        token.setMaxGauges(8);

        uint256 uniqueGauges;
        for (uint256 i = 0; i < 8; i++) {
            if (token.isGauge(gauges[i]) || gauges[i] == address(0)) {
                vm.expectRevert("ERC20Gauges: invalid gauge");
                token.addGauge(1, gauges[i]);
            } else {
                token.addGauge(1, gauges[i]);
                require(token.numGauges() == uniqueGauges + 1);
                require(token.gauges()[uniqueGauges] == gauges[i]);
                uniqueGauges++;
            }
        }
    }

    function testAddPreviouslyDeprecated(uint256 amount) public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);

        token.mint(address(this), amount);
        token.incrementGauge(gauge1, amount);

        token.removeGauge(gauge1);
        token.addGauge(1, gauge1);

        require(token.numGauges() == 1);
        require(token.totalWeight() == amount);
        require(token.getGaugeWeight(gauge1) == amount);
        require(token.getUserGaugeWeight(address(this), gauge1) == amount);
    }

    function testLiveAndDeprecatedGaugeGetters() public {
        require(token.numLiveGauges() == 0);
        require(token.liveGauges().length == 0);
        require(token.numDeprecatedGauges() == 0);
        require(token.deprecatedGauges().length == 0);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.numGauges() == 2);
        require(token.gauges()[0] == gauge1);
        require(token.gauges()[1] == gauge2);
        require(token.numLiveGauges() == 2);
        require(token.liveGauges().length == 2);
        require(token.liveGauges()[0] == gauge1);
        require(token.liveGauges()[1] == gauge2);
        require(token.numDeprecatedGauges() == 0);
        require(token.deprecatedGauges().length == 0);

        token.removeGauge(gauge1);

        require(token.numGauges() == 2);
        require(token.gauges()[0] == gauge1);
        require(token.gauges()[1] == gauge2);
        require(token.numLiveGauges() == 1);
        require(token.liveGauges().length == 1);
        require(token.liveGauges()[0] == gauge2);
        require(token.numDeprecatedGauges() == 1);
        require(token.deprecatedGauges().length == 1);
        require(token.deprecatedGauges()[0] == gauge1);

        token.addGauge(1, gauge1); // re-add previously deprecated

        require(token.numGauges() == 2);
        require(token.gauges()[0] == gauge1);
        require(token.gauges()[1] == gauge2);
        require(token.numLiveGauges() == 2);
        require(token.liveGauges().length == 2);
        require(token.liveGauges()[0] == gauge1);
        require(token.liveGauges()[1] == gauge2);
        require(token.numDeprecatedGauges() == 0);
        require(token.deprecatedGauges().length == 0);

        token.removeGauge(gauge2);

        require(token.numGauges() == 2);
        require(token.gauges()[0] == gauge1);
        require(token.gauges()[1] == gauge2);
        require(token.numLiveGauges() == 1);
        require(token.liveGauges().length == 1);
        require(token.liveGauges()[0] == gauge1);
        require(token.numDeprecatedGauges() == 1);
        require(token.deprecatedGauges().length == 1);
        require(token.deprecatedGauges()[0] == gauge2);

        token.removeGauge(gauge1);

        require(token.numGauges() == 2);
        require(token.gauges()[0] == gauge1);
        require(token.gauges()[1] == gauge2);
        require(token.numLiveGauges() == 0);
        require(token.liveGauges().length == 0);
        require(token.numDeprecatedGauges() == 2);
        require(token.deprecatedGauges().length == 2);
        require(token.deprecatedGauges()[0] == gauge2);
        require(token.deprecatedGauges()[1] == gauge1);
    }

    function testAddGaugeTwice() public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.addGauge(1, gauge1);
    }

    function testRemoveGauge() public {
        require(token.isDeprecatedGauge(gauge1) == false);
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.removeGauge(gauge1);
        require(token.numGauges() == 1);
        require(token.numDeprecatedGauges() == 1);
        require(token.deprecatedGauges()[0] == gauge1);
        require(token.isDeprecatedGauge(gauge1) == true);
    }

    function testRemoveGaugeTwice() public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.removeGauge(gauge1);
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.removeGauge(gauge1);
    }

    function testRemoveUnexistingGauge() public {
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.removeGauge(address(12345));
    }

    function testRemoveGaugeWithWeight(uint256 amount) public {
        token.mint(address(this), amount);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.incrementGauge(gauge1, amount);

        token.removeGauge(gauge1);
        require(token.numGauges() == 1);
        require(token.numDeprecatedGauges() == 1);
        require(token.totalWeight() == 0);
        require(token.getGaugeWeight(gauge1) == amount);
        require(token.getUserGaugeWeight(address(this), gauge1) == amount);
    }

    /*///////////////////////////////////////////////////////////////
                        TEST USER GAUGE OPERATIONS
    //////////////////////////////////////////////////////////////*/

    function testCalculateGaugeAllocation() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(3);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
    
        require(token.calculateGaugeAllocation(gauge1, 100e18) == 0);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 0);

        require(token.incrementGauge(gauge1, 1e18) == 1e18);
        require(token.incrementGauge(gauge2, 1e18) == 2e18);

        require(token.calculateGaugeAllocation(gauge1, 100e18) == 50e18);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 50e18);

        require(token.incrementGauge(gauge2, 2e18) == 4e18);

        require(token.calculateGaugeAllocation(gauge1, 100e18) == 25e18);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 75e18);

        token.removeGauge(gauge1);
        require(token.calculateGaugeAllocation(gauge1, 100e18) == 0);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 100e18);

        token.addGauge(2, gauge3); // 2nd gauge type
        assertEq(token.gaugeType(gauge1), 1);
        assertEq(token.gaugeType(gauge2), 1);
        assertEq(token.gaugeType(gauge3), 2);

        require(token.calculateGaugeAllocation(gauge1, 100e18) == 0);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 100e18);
        require(token.calculateGaugeAllocation(gauge3, 100e18) == 0);

        require(token.incrementGauge(gauge3, 1e18) == 5e18);
        assertEq(token.totalTypeWeight(1), 3e18);
        assertEq(token.totalTypeWeight(2), 1e18);

        require(token.calculateGaugeAllocation(gauge1, 100e18) == 0);
        require(token.calculateGaugeAllocation(gauge2, 100e18) == 100e18);
        require(token.calculateGaugeAllocation(gauge3, 100e18) == 100e18);
    }

    function testIncrement(
        address[8] memory from,
        address[8] memory gauges,
        uint256[8] memory amounts
    ) public {
        token.setMaxGauges(8);
        unchecked {
            uint256 sum;
            for (uint256 i = 0; i < 8; i++) {
                vm.assume(from[i] != address(0)); // cannot mint to address(0)
                vm.assume(
                    sum + amounts[i] >= sum &&
                        !token.isGauge(gauges[i]) &&
                        gauges[i] != address(0)
                );
                sum += amounts[i];

                token.mint(from[i], amounts[i]);

                uint256 userWeightBefore = token.getUserWeight(from[i]);
                uint256 userGaugeWeightBefore = token.getUserGaugeWeight(
                    from[i],
                    gauges[i]
                );
                uint256 gaugeWeightBefore = token.getGaugeWeight(gauges[i]);

                token.addGauge(1, gauges[i]);
                vm.prank(from[i]);
                token.incrementGauge(gauges[i], amounts[i]);

                require(
                    token.getUserWeight(from[i]) ==
                        userWeightBefore + amounts[i]
                );
                require(token.totalWeight() == sum);
                require(
                    token.getUserGaugeWeight(from[i], gauges[i]) ==
                        userGaugeWeightBefore + amounts[i]
                );
                require(
                    token.getGaugeWeight(gauges[i]) ==
                        gaugeWeightBefore + amounts[i]
                );
            }
        }
    }

    /// @notice test incrementing over user max
    function testIncrementOverMax() public {
        token.mint(address(this), 2e18);

        token.setMaxGauges(1);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        token.incrementGauge(gauge1, 1e18);
        vm.expectRevert("ERC20Gauges: exceed max gauges");
        token.incrementGauge(gauge2, 1e18);
    }

    /// @notice test incrementing at user max
    function testIncrementAtMax() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(1);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        token.incrementGauge(gauge1, 1e18);
        token.incrementGauge(gauge1, 1e18);

        require(token.getUserGaugeWeight(address(this), gauge1) == 2e18);
        require(token.getUserWeight(address(this)) == 2e18);
        require(token.getGaugeWeight(gauge1) == 2e18);
        require(token.totalWeight() == 2e18);
    }

    /// @notice test incrementing over user max
    function testIncrementOverMaxApproved(
        address[8] memory gauges,
        uint256[8] memory amounts,
        uint8 max
    ) public {
        token.setMaxGauges(max % 8);
        token.setCanExceedMaxGauges(address(this), true);

        unchecked {
            uint256 sum;
            for (uint256 i = 0; i < 8; i++) {
                vm.assume(
                    sum + amounts[i] >= sum &&
                        !token.isGauge(gauges[i]) &&
                        gauges[i] != address(0)
                );
                sum += amounts[i];

                token.mint(address(this), amounts[i]);

                uint256 userGaugeWeightBefore = token.getUserGaugeWeight(
                    address(this),
                    gauges[i]
                );
                uint256 gaugeWeightBefore = token.getGaugeWeight(gauges[i]);

                token.addGauge(1, gauges[i]);
                token.incrementGauge(gauges[i], amounts[i]);

                require(token.getUserWeight(address(this)) == sum);
                require(token.totalWeight() == sum);
                require(
                    token.getUserGaugeWeight(address(this), gauges[i]) ==
                        userGaugeWeightBefore + amounts[i]
                );
                require(
                    token.getGaugeWeight(gauges[i]) ==
                        gaugeWeightBefore + amounts[i]
                );
            }
        }
    }

    function testIncrementOnDeprecated(uint256 amount) public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.removeGauge(gauge1);
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.incrementGauge(gauge1, amount);
    }

    function testIncrementOnUnlisted(uint256 amount) public {
        token.setMaxGauges(1);
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.incrementGauge(gauge1, amount);
    }

    function testIncrementsOnUnlisted() public {
        token.setMaxGauges(1);
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.incrementGauges(new address[](1), new uint256[](1));
    }

    function testIncrementOverWeight(uint256 amount) public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        vm.assume(amount != type(uint256).max);
        token.mint(address(this), amount);

        require(token.incrementGauge(gauge1, amount) == amount);
        vm.expectRevert("ERC20Gauges: overweight");
        token.incrementGauge(gauge2, 1);
    }

    /// @notice test incrementing multiple gauges with different weights after already incrementing once
    function testIncrementGauges() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        token.incrementGauge(gauge1, 1e18);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 2e18;
        weights[1] = 4e18;

        require(token.incrementGauges(gaugeList, weights) == 7e18);

        require(token.getUserGaugeWeight(address(this), gauge2) == 2e18);
        require(token.getGaugeWeight(gauge2) == 2e18);
        require(token.getUserGaugeWeight(address(this), gauge1) == 5e18);
        require(token.getUserWeight(address(this)) == 7e18);
        require(token.getGaugeWeight(gauge1) == 5e18);
        require(token.totalWeight() == 7e18);
    }

    function testIncrementGaugesDeprecated() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
        token.removeGauge(gauge2);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 2e18;
        weights[1] = 4e18;
        vm.expectRevert("ERC20Gauges: invalid gauge");
        token.incrementGauges(gaugeList, weights);
    }

    function testIncrementGaugesOverweight() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 50e18;
        weights[1] = 51e18;
        vm.expectRevert("ERC20Gauges: overweight");
        token.incrementGauges(gaugeList, weights);
    }

    function testIncrementGaugesSizeMismatch() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
        token.removeGauge(gauge2);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](3);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 1e18;
        weights[1] = 2e18;
        vm.expectRevert("ERC20Gauges: size mismatch");
        token.incrementGauges(gaugeList, weights);
    }

    /// @notice test decrement twice, 2 tokens each after incrementing by 4.
    function testDecrement() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 4e18) == 4e18);

        require(token.decrementGauge(gauge1, 2e18) == 2e18);
        require(token.getUserGaugeWeight(address(this), gauge1) == 2e18);
        require(token.getUserWeight(address(this)) == 2e18);
        require(token.getGaugeWeight(gauge1) == 2e18);
        require(token.totalWeight() == 2e18);

        require(token.decrementGauge(gauge1, 2e18) == 0);
        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserWeight(address(this)) == 0);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.totalWeight() == 0);
    }

    /// @notice test decrement all removes user gauge.
    function testDecrementAllRemovesUserGauge() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 4e18) == 4e18);

        require(token.numUserGauges(address(this)) == 1);
        require(token.userGauges(address(this))[0] == gauge1);

        require(token.decrementGauge(gauge1, 4e18) == 0);

        require(token.numUserGauges(address(this)) == 0);
    }

    function testDecrementUnderflow(uint256 amount) public {
        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        token.mint(address(this), amount);

        vm.assume(amount != type(uint256).max);

        require(token.incrementGauge(gauge1, amount) == amount);
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 17));
        token.decrementGauge(gauge1, amount + 1);
    }

    function testDecrementDeprecatedGauge() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);

        require(token.incrementGauge(gauge1, 5e18) == 5e18);

        require(token.totalWeight() == 5e18);
        require(token.totalTypeWeight(1) == 5e18);
        require(token.getGaugeWeight(gauge1) == 5e18);
        require(token.getUserGaugeWeight(address(this), gauge1) == 5e18);
        require(token.getUserWeight(address(this)) == 5e18);

        token.removeGauge(gauge1);

        require(token.totalWeight() == 0);
        require(token.totalTypeWeight(1) == 0);
        require(token.getGaugeWeight(gauge1) == 5e18);
        require(token.getUserGaugeWeight(address(this), gauge1) == 5e18);
        require(token.getUserWeight(address(this)) == 5e18);

        require(token.decrementGauge(gauge1, 5e18) == 0);

        require(token.totalWeight() == 0);
        require(token.totalTypeWeight(1) == 0);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserWeight(address(this)) == 0);
    }

    function testDecrementGauges() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        token.incrementGauge(gauge1, 1e18);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 2e18;
        weights[1] = 4e18;

        require(token.incrementGauges(gaugeList, weights) == 7e18);

        weights[1] = 2e18;
        require(token.decrementGauges(gaugeList, weights) == 3e18);

        require(token.getUserGaugeWeight(address(this), gauge2) == 0);
        require(token.getGaugeWeight(gauge2) == 0);
        require(token.getUserGaugeWeight(address(this), gauge1) == 3e18);
        require(token.getUserWeight(address(this)) == 3e18);
        require(token.getGaugeWeight(gauge1) == 3e18);
        require(token.totalWeight() == 3e18);
    }

    function testDecrementGaugesOver() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 5e18;
        weights[1] = 5e18;

        require(token.incrementGauges(gaugeList, weights) == 10e18);

        weights[1] = 10e18;
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 17));
        token.decrementGauges(gaugeList, weights);
    }

    function testDecrementGaugesSizeMismatch() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        address[] memory gaugeList = new address[](2);
        uint256[] memory weights = new uint256[](2);
        gaugeList[0] = gauge2;
        gaugeList[1] = gauge1;
        weights[0] = 1e18;
        weights[1] = 2e18;

        require(token.incrementGauges(gaugeList, weights) == 3e18);
        vm.expectRevert("ERC20Gauges: size mismatch");
        token.decrementGauges(gaugeList, new uint256[](0));
    }

    /*///////////////////////////////////////////////////////////////
                            TEST ERC20 LOGIC
    //////////////////////////////////////////////////////////////*/

    function testDecrementUntilFreeWhenFree() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 10e18) == 10e18);
        require(token.incrementGauge(gauge2, 20e18) == 30e18);
        require(token.userUnusedWeight(address(this)) == 70e18);

        token.mockBurn(address(this), 50e18);
        require(token.userUnusedWeight(address(this)) == 20e18);

        require(token.getUserGaugeWeight(address(this), gauge1) == 10e18);
        require(token.getUserWeight(address(this)) == 30e18);
        require(token.getGaugeWeight(gauge1) == 10e18);
        require(token.getUserGaugeWeight(address(this), gauge2) == 20e18);
        require(token.getGaugeWeight(gauge2) == 20e18);
        require(token.totalWeight() == 30e18);
    }

    function testDecrementUntilFreeSingle() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 10e18) == 10e18);
        require(token.incrementGauge(gauge2, 20e18) == 30e18);
        require(token.userUnusedWeight(address(this)) == 70e18);

        token.transfer(address(1), 80e18);
        require(token.userUnusedWeight(address(this)) == 0);

        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserWeight(address(this)) == 20e18);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.getUserGaugeWeight(address(this), gauge2) == 20e18);
        require(token.getGaugeWeight(gauge2) == 20e18);
        require(token.totalWeight() == 20e18);
    }

    function testDecrementUntilFreeDouble() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 10e18) == 10e18);
        require(token.incrementGauge(gauge2, 20e18) == 30e18);
        require(token.userUnusedWeight(address(this)) == 70e18);

        token.approve(address(1), 100e18);
        vm.prank(address(1));
        token.transferFrom(address(this), address(1), 90e18);

        require(token.userUnusedWeight(address(this)) == 10e18);

        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserWeight(address(this)) == 0);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.getUserGaugeWeight(address(this), gauge2) == 0);
        require(token.getGaugeWeight(gauge2) == 0);
        require(token.totalWeight() == 0);
    }

    function testDecrementUntilFreeDeprecated() public {
        token.mint(address(this), 100e18);

        token.setMaxGauges(2);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);

        require(token.incrementGauge(gauge1, 10e18) == 10e18);
        require(token.incrementGauge(gauge2, 20e18) == 30e18);
        require(token.userUnusedWeight(address(this)) == 70e18);

        require(token.totalWeight() == 30e18);
        token.removeGauge(gauge1);
        require(token.totalWeight() == 20e18);

        assertEq(token.isDeprecatedGauge(gauge1), true);
        assertEq(token.isDeprecatedGauge(gauge2), false);
        assertEq(token.getUserGaugeWeight(address(this), gauge1), 10e18);
        assertEq(token.getUserGaugeWeight(address(this), gauge2), 20e18);
        assertEq(token.userGauges(address(this)).length, 2);

        token.mockBurn(address(this), 100e18);

        require(token.userUnusedWeight(address(this)) == 0);

        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserWeight(address(this)) == 0);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.getUserGaugeWeight(address(this), gauge2) == 0);
        require(token.getGaugeWeight(gauge2) == 0);
        require(token.totalWeight() == 0);
    }

    // Validate use case described in 2022-04 C4 audit issue:
    // [M-07] Incorrect accounting of free weight in _decrementWeightUntilFree
    function testDecrementUntilFreeBugM07() public {
        token.mint(address(this), 3e18);

        token.setMaxGauges(3);
        token.addGauge(1, gauge1);
        token.addGauge(1, gauge2);
        token.addGauge(1, gauge3);

        require(token.incrementGauge(gauge1, 1e18) == 1e18);
        require(token.incrementGauge(gauge2, 1e18) == 2e18);
        require(token.incrementGauge(gauge3, 1e18) == 3e18);

        require(token.userUnusedWeight(address(this)) == 0);
        require(token.totalWeight() == 3e18);
        token.removeGauge(gauge1);
        require(token.totalWeight() == 2e18);

        // deprecated gauge still counts, would need to decrement
        require(token.userUnusedWeight(address(this)) == 0);
        require(token.getUserGaugeWeight(address(this), gauge1) == 1e18);
        require(token.getUserGaugeWeight(address(this), gauge2) == 1e18);
        require(token.getUserGaugeWeight(address(this), gauge3) == 1e18);
        require(token.getUserWeight(address(this)) == 3e18);

        token.mockBurn(address(this), 2e18);

        require(token.userUnusedWeight(address(this)) == 0);
        require(token.getUserGaugeWeight(address(this), gauge1) == 0);
        require(token.getUserGaugeWeight(address(this), gauge2) == 0);
        require(token.getUserGaugeWeight(address(this), gauge3) == 1e18);
        require(token.getUserWeight(address(this)) == 1e18);
        require(token.getGaugeWeight(gauge1) == 0);
        require(token.getGaugeWeight(gauge2) == 0);
        require(token.getGaugeWeight(gauge3) == 1e18);
        require(token.totalWeight() == 1e18);
    }
}
