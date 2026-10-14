// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {Proxied} from "./Mocks.sol";

/// What an upgrade installs: the same contract, plus one function to tell it by.
contract DataRegistryUpgradeMock is DataRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// The DataRegistry on its own. WRITER stands in for the AppRegistry, the one address
/// that may commit; who may publish is the AppRegistry's check, tested with it.
contract DataRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant PUB = 0x2222222222222222222222222222222222222222;
    address constant WRITER = 0x3333333333333333333333333333333333333333;
    bytes32 constant APP = bytes32(uint256(1));
    bytes32 constant SUB_A = bytes32(uint256(2));
    bytes32 constant SUB_B = bytes32(uint256(3));
    bytes32 constant ROOT_A = bytes32(uint256(5));
    bytes32 constant ROOT_B = bytes32(uint256(6));

    event StateCommitted(
        bytes32 indexed namespace_key,
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 subspace_id,
        bytes32 old_root,
        bytes32 new_root
    );

    DataRegistry registry;

    function setUp() public {
        registry = Proxied.dataRegistry(ADMIN, WRITER);
    }

    /// A commit for PUB, as the AppRegistry forwards it.
    function commit(bytes32 subspace, bytes32 oldRoot, bytes32 newRoot) internal {
        vm.prank(WRITER);
        registry.commitStateRoot(APP, PUB, subspace, oldRoot, newRoot);
    }

    function test_initialization() public view {
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.appRegistry(), WRITER);
    }

    /// Nobody but the AppRegistry commits: not the publisher, not the admin.
    function test_only_the_app_registry_commits() public {
        address[2] memory others = [PUB, ADMIN];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(DataRegistry.Unauthorized.selector);
            registry.commitStateRoot(APP, PUB, SUB_A, bytes32(0), ROOT_A);
        }
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), bytes32(0));

        commit(SUB_A, bytes32(0), ROOT_A);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);
    }

    /// Repointing moves the right to commit, and only the admin can do it.
    function test_repointing_moves_the_right_to_commit() public {
        address next = makeAddr("next");
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setAppRegistry(PUB);

        vm.prank(ADMIN);
        registry.setAppRegistry(next);
        assertEq(registry.appRegistry(), next);
        vm.prank(WRITER);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.commitStateRoot(APP, PUB, SUB_A, bytes32(0), ROOT_A);
        vm.prank(next);
        registry.commitStateRoot(APP, PUB, SUB_A, bytes32(0), ROOT_A);

        // Unset, it belongs to nobody: no transaction comes from the zero address.
        vm.prank(ADMIN);
        registry.setAppRegistry(address(0));
        vm.prank(next);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.commitStateRoot(APP, PUB, SUB_A, ROOT_A, ROOT_B);
    }

    /// Golden fixture shared with the SDK (`namespace-key.test.ts`). The client derives
    /// this key to filter events and to address heads; if the derivations ever diverge,
    /// every read silently returns a zero root.
    function test_namespace_key_matches_sdk_fixture() public {
        bytes32 appId = keccak256("fangorn");
        bytes32 subspaceId = keccak256("docs");
        assertEq(appId, 0xe9cb5c7e3e8fb962393e314a9387731152c9b2e3cfb1fcbfe79c0c3038b2ed37);
        assertEq(subspaceId, 0x6bf9054545420e9e9f4aa4f353a32c7d0d52c11dbcdda56c53be8375cafeebb1);

        vm.expectEmit(true, true, true, true, address(registry));
        emit StateCommitted(
            0xcfde128f9c8e22771b4caeabe644f7abd0c1d1c50e27562b263934f9279ad3ca,
            appId,
            PUB,
            subspaceId,
            bytes32(0),
            ROOT_A
        );
        vm.prank(WRITER);
        registry.commitStateRoot(appId, PUB, subspaceId, bytes32(0), ROOT_A);
    }

    /// A missing head can be restored once; a live one can never be rewritten.
    function test_seed_namespace_head_is_fill_only() public {
        bytes32 root = bytes32(uint256(9));

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.seedNamespaceHead(APP, PUB, SUB_A, root);

        vm.startPrank(ADMIN);
        registry.seedNamespaceHead(APP, PUB, SUB_A, root);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), root);

        // Overwriting a live timeline would be a backdoor, not a migration.
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.seedNamespaceHead(APP, PUB, SUB_A, bytes32(uint256(8)));
        vm.stopPrank();
    }

    /// Each publisher and each subspace has its own timeline.
    function test_timelines_are_isolated() public {
        commit(SUB_A, bytes32(0), ROOT_A);
        // SUB_B is untouched and still starts from zero
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_B), bytes32(0));
        commit(SUB_B, bytes32(0), ROOT_B);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_B), ROOT_B);

        // The same app and subspace under another publisher is another timeline.
        assertEq(registry.getNamespaceHead(APP, ADMIN, SUB_A), bytes32(0));
        vm.prank(WRITER);
        registry.commitStateRoot(APP, ADMIN, SUB_A, bytes32(0), ROOT_B);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);
    }

    function test_stale_state_root_is_rejected() public {
        vm.prank(WRITER);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.commitStateRoot(APP, PUB, SUB_A, ROOT_A, ROOT_B);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// A new implementation takes over the same address and the same state — every
    /// namespace head — and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        commit(SUB_A, bytes32(0), ROOT_A);
        address v2 = address(new DataRegistryUpgradeMock());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        registry.upgradeToAndCall(v2, "");

        assertEq(DataRegistryUpgradeMock(address(registry)).version(), 2);
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.appRegistry(), WRITER);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);

        // The timeline continues from where it was.
        commit(SUB_A, ROOT_A, ROOT_B);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_B);
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(PUB, WRITER);

        DataRegistry implementation = new DataRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(PUB, WRITER);
    }

    /// The admin role moves, and the right to upgrade moves with it.
    function test_the_admin_role_can_be_handed_over() public {
        address v2 = address(new DataRegistryUpgradeMock());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setAdmin(PUB);

        vm.prank(ADMIN);
        registry.setAdmin(PUB);
        assertEq(registry.admin(), PUB);

        vm.prank(ADMIN);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");
        vm.prank(PUB);
        registry.upgradeToAndCall(v2, "");
    }
}
