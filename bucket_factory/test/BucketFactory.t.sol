// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BucketFactory} from "../src/BucketFactory.sol";

/// Stand-in for the Stylus Bucket implementation. A clone delegatecalls this,
/// so `initialize` writes to the clone's own storage.
contract MockBucket {
    address public owner;
    address public registry;
    bool private initialized;

    function initialize(address _owner, address _registry) external {
        require(!initialized, "already initialized");
        initialized = true;
        owner = _owner;
        registry = _registry;
    }
}

contract BucketFactoryTest is Test {
    BucketFactory factory;
    address impl;
    address registry = address(this);
    address alice = address(0xA11CE);

    function setUp() public {
        impl = address(new MockBucket());
        factory = new BucketFactory(impl, registry);
    }

    function test_createBucket_clonesAndInitializes() public {
        address bucket = factory.createBucket(alice);
        assertTrue(bucket != address(0));
        assertTrue(bucket != impl); // it's a clone, not the impl
        assertEq(MockBucket(bucket).owner(), alice);
        assertEq(MockBucket(bucket).registry(), registry);
    }

    function test_createBucket_onlyRegistry() public {
        vm.prank(alice);
        vm.expectRevert(BucketFactory.Unauthorized.selector);
        factory.createBucket(alice);
    }

    function test_eachPublisherGetsDistinctBucket() public {
        address b1 = factory.createBucket(alice);
        address b2 = factory.createBucket(address(0xB0B));
        assertTrue(b1 != b2);
    }
}
