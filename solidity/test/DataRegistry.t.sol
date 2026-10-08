// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DataRegistry} from "../src/DataRegistry.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MockAppRegistry, Reverter, Proxied} from "./Mocks.sol";

/// The cases from `stylus/data_registry`'s tests, plus the ones TestVM could not
/// express (an AppRegistry that is missing or misbehaving).
/// What an upgrade installs: the same contract, plus one function to tell it by.
contract DataRegistryV2 is DataRegistry {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract DataRegistryTest is Test {
    address constant ADMIN = 0x1111111111111111111111111111111111111111;
    address constant PUB = 0x2222222222222222222222222222222222222222;
    uint256 constant FEE = 1 ether;
    bytes32 constant APP = bytes32(uint256(1));
    bytes32 constant SUB_A = bytes32(uint256(2));
    bytes32 constant SUB_B = bytes32(uint256(3));
    bytes32 constant ROOT_A = bytes32(uint256(5));
    bytes32 constant ROOT_B = bytes32(uint256(6));

    uint8 constant STATUS_ACTIVE = 1;
    uint8 constant STATUS_SUSPENDED = 2;

    event StateCommitted(
        bytes32 indexed namespace_key,
        bytes32 indexed app_id,
        address indexed publisher,
        bytes32 subspace_id,
        bytes32 old_root,
        bytes32 new_root
    );

    DataRegistry registry;
    MockAppRegistry apps;

    /// An app with PUB joined, and PUB registered globally.
    function setUp() public {
        apps = new MockAppRegistry();
        registry = Proxied.dataRegistry(ADMIN, FEE, address(apps));
        apps.setMember(APP, PUB, true);
        vm.deal(PUB, 10 ether);
        vm.prank(PUB);
        registry.register{value: FEE}();
    }

    function test_initialization() public {
        DataRegistry fresh = Proxied.dataRegistry(ADMIN, FEE, address(apps));
        assertEq(fresh.admin(), ADMIN);
        assertEq(fresh.registrationFee(), FEE);
        assertEq(fresh.publisherCount(), 0);
        assertEq(fresh.appRegistry(), address(apps));
    }

    function test_registration_requires_the_fee() public {
        address newcomer = makeAddr("newcomer");
        vm.prank(newcomer);
        vm.expectRevert(DataRegistry.RegistrationFeeRequired.selector);
        registry.register();
        assertFalse(registry.isRegistered(newcomer));
    }

    function test_registration_then_duplicate_is_refused() public {
        assertTrue(registry.isRegistered(PUB));
        assertEq(registry.getPublisherStatus(PUB), STATUS_ACTIVE);
        assertEq(registry.publisherCount(), 1);

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.AlreadyRegistered.selector);
        registry.register{value: FEE}();
    }

    function test_admin_suspension_flow() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.suspendPublisher(PUB);

        vm.prank(ADMIN);
        registry.suspendPublisher(PUB);
        assertEq(registry.getPublisherStatus(PUB), STATUS_SUSPENDED);
        assertEq(registry.publisherCount(), 0);
        assertFalse(registry.isRegistered(PUB));
    }

    function test_suspended_publisher_cannot_reinstate_themselves() public {
        vm.prank(ADMIN);
        registry.suspendPublisher(PUB);

        // Paying the fee again is not a way back in, and neither is the admin route.
        vm.startPrank(PUB);
        vm.expectRevert(DataRegistry.PublisherSuspendedErr.selector);
        registry.register{value: FEE}();
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.reinstateGlobal(PUB);
        vm.stopPrank();
        assertEq(registry.getPublisherStatus(PUB), STATUS_SUSPENDED);
        assertEq(registry.publisherCount(), 0);

        // Only a suspended publisher can be reinstated.
        vm.startPrank(ADMIN);
        vm.expectRevert(DataRegistry.NotRegistered.selector);
        registry.reinstateGlobal(ADMIN);
        registry.reinstateGlobal(PUB);
        vm.stopPrank();
        assertEq(registry.getPublisherStatus(PUB), STATUS_ACTIVE);
        assertEq(registry.publisherCount(), 1);
    }

    function test_suspended_publisher_cannot_commit() public {
        vm.prank(ADMIN);
        registry.suspendPublisher(PUB);

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.PublisherSuspendedErr.selector);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
    }

    function test_unregistered_wallet_cannot_commit() public {
        address newcomer = makeAddr("newcomer");
        apps.setMember(APP, newcomer, true); // app membership alone is not enough
        vm.prank(newcomer);
        vm.expectRevert(DataRegistry.NotRegistered.selector);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
    }

    /// Golden fixture shared with the SDK (`namespace-key.test.ts`) and the Stylus
    /// contract. The client derives this key to filter events and to address heads;
    /// if the derivations ever diverge, every read silently returns a zero root.
    function test_namespace_key_matches_sdk_fixture() public {
        bytes32 appId = keccak256("fangorn");
        bytes32 subspaceId = keccak256("docs");
        assertEq(appId, 0xe9cb5c7e3e8fb962393e314a9387731152c9b2e3cfb1fcbfe79c0c3038b2ed37);
        assertEq(subspaceId, 0x6bf9054545420e9e9f4aa4f353a32c7d0d52c11dbcdda56c53be8375cafeebb1);
        apps.setMember(appId, PUB, true);

        vm.expectEmit(true, true, true, true, address(registry));
        emit StateCommitted(
            0xcfde128f9c8e22771b4caeabe644f7abd0c1d1c50e27562b263934f9279ad3ca,
            appId,
            PUB,
            subspaceId,
            bytes32(0),
            ROOT_A
        );
        vm.prank(PUB);
        registry.commitStateRoot(appId, subspaceId, bytes32(0), ROOT_A);
    }

    /// A globally registered publisher who never joined the app must not be able to
    /// write under it. An app nobody claimed is an app nobody joined: same branch.
    function test_publisher_not_registered_for_app_is_rejected() public {
        apps.setMember(APP, PUB, false);
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.NotRegisteredForApp.selector);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
    }

    /// Anything but a clean `true` from the AppRegistry is a no: no contract at the
    /// address, a registry that reverts, and an unset registry all refuse the commit
    /// rather than reverting some other way or letting it through.
    function test_a_missing_or_broken_app_registry_fails_closed() public {
        address[3] memory broken = [address(0), makeAddr("no-code"), address(new Reverter())];
        for (uint256 i = 0; i < broken.length; i++) {
            vm.prank(ADMIN);
            registry.setAppRegistry(broken[i]);
            vm.prank(PUB);
            vm.expectRevert(DataRegistry.NotRegisteredForApp.selector);
            registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
        }
    }

    function test_only_the_admin_repoints_the_app_registry() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setAppRegistry(PUB);

        vm.prank(ADMIN);
        registry.setAppRegistry(PUB);
        assertEq(registry.appRegistry(), PUB);
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

    /// A registration can be restored once; a wallet the registry knows is left alone.
    function test_seed_publisher_is_fill_only() public {
        address migrated = makeAddr("migrated");

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.seedPublisher(migrated);

        vm.startPrank(ADMIN);
        // No fee is paid: the admin is restoring a registration, not selling one.
        registry.seedPublisher(migrated);
        assertTrue(registry.isRegistered(migrated));
        assertEq(registry.publisherCount(), 2);

        vm.expectRevert(DataRegistry.AlreadyRegistered.selector);
        registry.seedPublisher(migrated);

        // Seeding is not a way around a ban.
        registry.suspendPublisher(migrated);
        vm.expectRevert(DataRegistry.AlreadyRegistered.selector);
        registry.seedPublisher(migrated);
        assertEq(registry.getPublisherStatus(migrated), STATUS_SUSPENDED);
        vm.stopPrank();
    }

    function test_subspaces_have_isolated_timelines() public {
        vm.startPrank(PUB);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
        // SUB_B is untouched and still starts from zero
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_B), bytes32(0));

        registry.commitStateRoot(APP, SUB_B, bytes32(0), ROOT_B);
        vm.stopPrank();
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_B), ROOT_B);
    }

    function test_reactivation_retains_timeline_history() public {
        vm.prank(PUB);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);

        vm.startPrank(ADMIN);
        registry.suspendPublisher(PUB);
        registry.reinstateGlobal(PUB);
        vm.stopPrank();
        assertEq(registry.getPublisherStatus(PUB), STATUS_ACTIVE);
        assertEq(registry.publisherCount(), 1);

        // The head survived the suspension, and the CAS continues from it.
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);
        vm.prank(PUB);
        registry.commitStateRoot(APP, SUB_A, ROOT_A, ROOT_B);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_B);
    }

    function test_stale_state_root_is_rejected() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.StaleStateRoot.selector);
        registry.commitStateRoot(APP, SUB_A, ROOT_A, ROOT_B);
    }

    function test_only_the_admin_sets_the_registration_fee() public {
        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.setRegistrationFee(0);

        vm.prank(ADMIN);
        registry.setRegistrationFee(0);
        assertEq(registry.registrationFee(), 0);
    }

    // ── upgrades ──────────────────────────────────────────────────────────────

    /// A new implementation takes over the same address and the same state — every
    /// registration and namespace head — and only the admin can install one.
    function test_an_upgrade_keeps_state_and_only_the_admin_can_do_it() public {
        vm.prank(PUB);
        registry.commitStateRoot(APP, SUB_A, bytes32(0), ROOT_A);
        address v2 = address(new DataRegistryV2());

        vm.prank(PUB);
        vm.expectRevert(DataRegistry.Unauthorized.selector);
        registry.upgradeToAndCall(v2, "");

        vm.prank(ADMIN);
        registry.upgradeToAndCall(v2, "");

        assertEq(DataRegistryV2(address(registry)).version(), 2);
        assertEq(registry.admin(), ADMIN);
        assertEq(registry.registrationFee(), FEE);
        assertEq(registry.appRegistry(), address(apps));
        assertEq(registry.publisherCount(), 1);
        assertEq(registry.getPublisherStatus(PUB), STATUS_ACTIVE);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_A);

        // The timeline continues from where it was.
        vm.prank(PUB);
        registry.commitStateRoot(APP, SUB_A, ROOT_A, ROOT_B);
        assertEq(registry.getNamespaceHead(APP, PUB, SUB_A), ROOT_B);
    }

    /// `initialize` stands in for the constructor, so it runs exactly once — and never
    /// on the bare implementation, which nobody should be able to take over.
    function test_initialize_runs_once_and_never_on_the_implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        registry.initialize(PUB, 0, address(apps));

        DataRegistry implementation = new DataRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(PUB, 0, address(apps));
    }

    /// The admin role moves, and the right to upgrade moves with it.
    function test_the_admin_role_can_be_handed_over() public {
        address v2 = address(new DataRegistryV2());

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
