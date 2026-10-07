// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SettlementRegistry} from "../src/SettlementRegistry.sol";
import {MockUSDC, MockSemaphore, ShortSemaphore, MockHook} from "./Mocks.sol";

/// A hook that settles once more from inside `afterSettle`. Once only: if the
/// registry allowed it, the inner settle would succeed and so would the outer one.
contract ReenteringHook {
    SettlementRegistry immutable registry;
    bool entered;

    constructor(SettlementRegistry r) {
        registry = r;
    }

    function afterSettle(bytes32 resourceId, uint256 nullifierHash, uint256, bytes calldata) external {
        if (entered) return;
        entered = true;
        uint256[8] memory points;
        registry.settle(resourceId, address(this), 20, 123, nullifierHash + 1, 7, points, new uint8[](0));
    }
}

/// The cases from `stylus/settlement_registry`'s tests.
///
/// The Rust tests had to pin "which group, which recipient" indirectly, by mocking
/// the exact calldata they expected and making it revert. These mocks record what
/// they were called with, so the same properties are asserted directly.
contract SettlementRegistryTest is Test {
    address constant OWNER = 0x3333333333333333333333333333333333333333;
    address constant BUYER = 0x4444444444444444444444444444444444444444;
    address constant STEALTH = 0x6666666666666666666666666666666666666666;
    address constant ADMIN = 0x7777777777777777777777777777777777777777;
    address constant ATTACKER = 0x8888888888888888888888888888888888888888;
    address constant STRANGER = 0x9999999999999999999999999999999999999999;

    bytes32 constant UID = bytes32(uint256(0xaa));
    bytes32 constant UID2 = bytes32(uint256(0xbb));
    uint256 constant PRICE = 1_000_000; // 1 USDC
    uint256 constant GROUP_A = 7; // the mock hands out 7, 8, …
    uint256 constant GROUP_B = 8;
    uint256 constant COMMITMENT = 42;
    uint256 constant NULLIFIER = 99;

    SettlementRegistry registry;
    MockUSDC usdc;
    MockSemaphore semaphore;
    MockHook hook;
    /// OWNER's UID at PRICE, in group GROUP_A.
    bytes32 rid;

    function setUp() public {
        usdc = new MockUSDC();
        semaphore = new MockSemaphore();
        hook = new MockHook();
        registry = new SettlementRegistry(address(usdc), address(semaphore), ADMIN);
        vm.prank(OWNER);
        rid = registry.createResource(UID, PRICE, "ipfs://x");
    }

    function idOf(address publisher, bytes32 uid) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(publisher, uid));
    }

    function doRegister(bytes32 resource, uint256 commitment, uint256 amount) internal {
        registry.register(
            resource,
            commitment,
            BUYER,
            amount,
            0,
            type(uint64).max,
            bytes32(uint256(9)),
            27,
            bytes32(uint256(1)),
            bytes32(uint256(2))
        );
    }

    function doSettle(bytes32 resource, uint256 nullifier) internal {
        uint256[8] memory points = [uint256(0), 1, 2, 3, 4, 5, 6, 7];
        registry.settle(resource, STEALTH, 20, 123, nullifier, 7, points, new uint8[](0));
    }

    // ── constructor / admin ───────────────────────────────────────────────────

    function test_constructor_stores_addresses_and_admin() public view {
        assertEq(registry.getUsdc(), address(usdc));
        assertEq(registry.getSemaphore(), address(semaphore));
        assertEq(registry.getAdmin(), ADMIN);
    }

    function test_admin_can_hand_over_and_renounce() public {
        vm.prank(ADMIN);
        registry.setAdmin(STRANGER);
        assertEq(registry.getAdmin(), STRANGER);

        // The old admin is now powerless.
        vm.prank(ADMIN);
        vm.expectRevert(SettlementRegistry.NotAdmin.selector);
        registry.setAdmin(ADMIN);

        vm.prank(STRANGER);
        registry.setAdmin(address(0));
        assertEq(registry.getAdmin(), address(0));

        // Renounced for good: nobody can claim it back, the zero address included.
        vm.prank(STRANGER);
        vm.expectRevert(SettlementRegistry.NotAdmin.selector);
        registry.setAdmin(STRANGER);
        vm.prank(address(0));
        vm.expectRevert(SettlementRegistry.NotAdmin.selector);
        registry.setAdmin(STRANGER);
    }

    function test_stranger_cannot_take_admin() public {
        vm.prank(STRANGER);
        vm.expectRevert(SettlementRegistry.NotAdmin.selector);
        registry.setAdmin(STRANGER);
        assertEq(registry.getAdmin(), ADMIN);
    }

    // ── createResource ────────────────────────────────────────────────────────

    function test_create_resource_derives_id_and_stores_state() public view {
        assertEq(rid, idOf(OWNER, UID));
        assertEq(registry.resourceIdFor(OWNER, UID), rid);
        assertEq(registry.getOwner(rid), OWNER);
        assertEq(registry.getPrice(rid), PRICE);
        assertEq(registry.getUri(rid), "ipfs://x");
        assertEq(registry.getGroupId(rid), GROUP_A);
        assertFalse(registry.isDisabled(rid));
    }

    /// The anti-squatting property: two publishers, one uid, two resources.
    function test_create_resource_cannot_be_squatted() public {
        vm.prank(ATTACKER);
        bytes32 stolen = registry.createResource(UID, 1, "ipfs://evil");

        assertTrue(stolen != rid, "the same uid under a different sender must be a different resource");
        assertEq(registry.getOwner(rid), OWNER, "the real publisher keeps their resource");
        assertEq(registry.getOwner(stolen), ATTACKER);
        assertEq(registry.getPrice(rid), PRICE, "and their price");
    }

    function test_create_resource_rejects_duplicate_from_same_publisher() public {
        vm.prank(OWNER);
        vm.expectRevert(SettlementRegistry.AlreadyRegistered.selector);
        registry.createResource(UID, 1, "");
        assertEq(registry.getPrice(rid), PRICE);
        assertEq(registry.getGroupId(rid), GROUP_A, "the group must not be replaced");
    }

    /// One group per resource. This is the property the whole design rests on.
    function test_create_resource_makes_a_group_per_resource() public {
        vm.prank(OWNER);
        bytes32 ridB = registry.createResource(UID2, PRICE, "");
        assertTrue(rid != ridB);
        assertEq(registry.getGroupId(ridB), GROUP_B);
        assertTrue(registry.getGroupId(rid) != registry.getGroupId(ridB), "two resources must never share a group");
    }

    function test_create_resource_propagates_semaphore_revert() public {
        semaphore.setFail(true, false, false);
        vm.prank(OWNER);
        vm.expectRevert(SettlementRegistry.SemaphoreCallFailed.selector);
        registry.createResource(UID2, PRICE, "");
        // Nothing half-built.
        assertEq(registry.getOwner(idOf(OWNER, UID2)), address(0));
    }

    function test_create_resource_fails_on_short_semaphore_return() public {
        SettlementRegistry short = new SettlementRegistry(address(usdc), address(new ShortSemaphore()), ADMIN);
        vm.prank(OWNER);
        vm.expectRevert(SettlementRegistry.SemaphoreCallFailed.selector);
        short.createResource(UID, PRICE, "");
    }

    /// v1 seeded a fake member into every new group. Nothing can prove membership
    /// with it, and it polluted every client-side group rebuild.
    function test_create_resource_adds_no_phantom_member() public view {
        assertEq(semaphore.adds(), 0);
    }

    // ── register ──────────────────────────────────────────────────────────────

    function test_register_requires_existing_resource() public {
        vm.expectRevert(SettlementRegistry.ResourceNotFound.selector);
        doRegister(idOf(OWNER, UID2), 1, PRICE);
    }

    function test_register_rejects_wrong_amount() public {
        vm.expectRevert(SettlementRegistry.IncorrectPaymentAmount.selector);
        doRegister(rid, 1, PRICE - 1);
        vm.expectRevert(SettlementRegistry.IncorrectPaymentAmount.selector);
        doRegister(rid, 1, PRICE + 1);
        assertFalse(registry.isRegistered(rid, 1));
        assertEq(usdc.calls(), 0);
    }

    /// v1's critical bug: the recipient was a caller-supplied argument. The money
    /// goes to the resource owner, read from storage — never to the buyer or anyone
    /// the caller names.
    function test_register_pays_the_resource_owner() public {
        vm.prank(BUYER);
        doRegister(rid, COMMITMENT, PRICE);
        assertEq(usdc.calls(), 1);
        assertEq(usdc.lastFrom(), BUYER);
        assertEq(usdc.lastTo(), OWNER, "register must pay the resource owner");
        assertEq(usdc.lastAmount(), PRICE);
    }

    function test_register_adds_member_to_that_resources_group() public {
        vm.prank(OWNER);
        bytes32 ridB = registry.createResource(UID2, PRICE, "");

        doRegister(ridB, COMMITMENT, PRICE);
        assertEq(semaphore.lastAddGroup(), GROUP_B, "register must add to the resource's own group");
        assertEq(semaphore.lastAddCommitment(), COMMITMENT);
    }

    function test_register_propagates_semaphore_failure_without_recording() public {
        semaphore.setFail(false, true, false);
        vm.expectRevert(SettlementRegistry.SemaphoreCallFailed.selector);
        doRegister(rid, COMMITMENT, PRICE);
        assertFalse(registry.isRegistered(rid, COMMITMENT));
        // The revert unwound the payment along with everything else.
        assertEq(usdc.calls(), 0);
    }

    function test_register_succeeds_then_rejects_replay() public {
        assertFalse(registry.isRegistered(rid, COMMITMENT));
        doRegister(rid, COMMITMENT, PRICE);
        assertTrue(registry.isRegistered(rid, COMMITMENT));
        assertFalse(registry.isRegistered(rid, 43), "another buyer is still unregistered");

        vm.expectRevert(SettlementRegistry.AlreadyRegistered.selector);
        doRegister(rid, COMMITMENT, PRICE);
    }

    /// The same buyer identity paying for a SECOND resource must work. Under v1's
    /// single shared group it could not.
    function test_same_buyer_can_pay_for_a_second_resource() public {
        vm.prank(OWNER);
        bytes32 ridB = registry.createResource(UID2, PRICE, "");

        doRegister(rid, COMMITMENT, PRICE);
        doRegister(ridB, COMMITMENT, PRICE);
        assertTrue(registry.isRegistered(rid, COMMITMENT));
        assertTrue(registry.isRegistered(ridB, COMMITMENT));
    }

    function test_register_propagates_transfer_revert_without_recording() public {
        usdc.setMode(MockUSDC.Mode.Revert);
        vm.expectRevert(SettlementRegistry.TransferFailed.selector);
        doRegister(rid, COMMITMENT, PRICE);
        assertFalse(registry.isRegistered(rid, COMMITMENT), "a failed payment must leave no registration");
        assertEq(semaphore.adds(), 0, "a failed payment must not join the group");
    }

    function test_free_resource_skips_the_transfer() public {
        vm.prank(OWNER);
        bytes32 free = registry.createResource(UID2, 0, "");

        // Any transfer at all would revert.
        usdc.setMode(MockUSDC.Mode.Revert);
        doRegister(free, COMMITMENT, 0);
        assertTrue(registry.isRegistered(free, COMMITMENT));
    }

    // ── settle ────────────────────────────────────────────────────────────────

    function test_settle_requires_existing_resource() public {
        vm.expectRevert(SettlementRegistry.ResourceNotFound.selector);
        doSettle(idOf(OWNER, UID2), 1);
    }

    /// The core property: the proof is verified against THIS resource's group, with
    /// this resource as the scope.
    function test_settle_verifies_against_this_resources_group_and_scope() public {
        doSettle(rid, NULLIFIER);
        assertEq(semaphore.lastProofGroup(), GROUP_A);
        assertEq(semaphore.lastProofScope(), uint256(rid));
        assertEq(semaphore.lastProofNullifier(), NULLIFIER);
    }

    function test_settle_propagates_a_rejected_proof() public {
        semaphore.setFail(false, false, true);
        vm.expectRevert(SettlementRegistry.VerificationFailed.selector);
        doSettle(rid, NULLIFIER);
        assertFalse(registry.isSettled(STEALTH, rid));
    }

    /// The v1 exploit, as a regression test. An attacker mints a free resource of
    /// their own, joins ITS group, then tries to settle the victim's. Settling the
    /// victim's resource consults the victim's group and scope — never the
    /// attacker's — so membership earned elsewhere is not evidence of anything.
    function test_a_free_resource_does_not_unlock_someone_elses() public {
        vm.startPrank(ATTACKER);
        bytes32 freebie = registry.createResource(UID, 0, "");
        assertTrue(freebie != rid);
        doRegister(freebie, COMMITMENT, 0);
        assertTrue(
            registry.getGroupId(freebie) != registry.getGroupId(rid),
            "a resource anyone can join for free must not share a group with a paid one"
        );

        doSettle(rid, NULLIFIER);
        vm.stopPrank();
        assertEq(semaphore.lastProofGroup(), GROUP_A, "settle consulted a group the attacker could join");
        assertEq(semaphore.lastProofScope(), uint256(rid));
        assertEq(semaphore.proofs(), 1);
    }

    function test_settle_marks_settled_then_rejects_nullifier_replay() public {
        assertFalse(registry.isSettled(STEALTH, rid));
        doSettle(rid, NULLIFIER);
        assertTrue(registry.isSettled(STEALTH, rid));
        assertFalse(registry.isSettled(BUYER, rid), "settlement is per stealth address");

        vm.expectRevert(SettlementRegistry.AlreadySettled.selector);
        doSettle(rid, NULLIFIER);
    }

    /// Semaphore scopes a nullifier per (identity, resource), so the same one on a
    /// second resource cannot be genuine. Seeing it means a forgery: reject it.
    function test_a_nullifier_is_spent_once_across_the_registry() public {
        vm.prank(OWNER);
        bytes32 ridB = registry.createResource(UID2, PRICE, "");

        doSettle(rid, NULLIFIER);
        vm.expectRevert(SettlementRegistry.AlreadySettled.selector);
        doSettle(ridB, NULLIFIER);

        // A distinct nullifier settles normally.
        doSettle(ridB, NULLIFIER + 1);
        assertTrue(registry.isSettled(STEALTH, ridB));
    }

    function test_settle_runs_registered_hook_with_the_hook_data() public {
        vm.prank(OWNER);
        registry.registerHook(rid, address(hook));

        uint256[8] memory points;
        uint8[] memory data = new uint8[](3);
        data[0] = 0xde;
        data[1] = 0xad;
        data[2] = 0x01;
        registry.settle(rid, STEALTH, 20, 123, NULLIFIER, 7, points, data);

        assertTrue(registry.isSettled(STEALTH, rid));
        assertEq(hook.calls(), 1);
        assertEq(hook.lastResource(), rid);
        assertEq(hook.lastNullifier(), NULLIFIER);
        assertEq(hook.lastMessage(), 7);
        // `settle` takes uint8[]; the hook receives the same bytes.
        assertEq(hook.lastData(), hex"dead01");
    }

    function test_settle_propagates_hook_failure_and_unwinds() public {
        vm.prank(OWNER);
        registry.registerHook(rid, address(hook));
        hook.setFail(true);

        vm.expectRevert(SettlementRegistry.HookFailed.selector);
        doSettle(rid, NULLIFIER);
        assertFalse(registry.isSettled(STEALTH, rid));

        // The nullifier was not burned by the failed attempt.
        hook.setFail(false);
        doSettle(rid, NULLIFIER);
        assertTrue(registry.isSettled(STEALTH, rid));
    }

    /// Stylus refuses reentrant calls by default; the port has to say so itself.
    function test_a_hook_cannot_reenter_settle() public {
        ReenteringHook reenter = new ReenteringHook(registry);
        vm.prank(OWNER);
        registry.registerHook(rid, address(reenter));

        vm.expectRevert(SettlementRegistry.HookFailed.selector);
        doSettle(rid, NULLIFIER);
        assertFalse(registry.isSettled(address(reenter), rid));
    }

    // ── takedown ──────────────────────────────────────────────────────────────

    function test_owner_can_disable_and_reenable() public {
        vm.prank(OWNER);
        registry.setDisabled(rid, true);
        assertTrue(registry.isDisabled(rid));

        vm.expectRevert(SettlementRegistry.ResourceIsDisabled.selector);
        doRegister(rid, COMMITMENT, PRICE);
        vm.expectRevert(SettlementRegistry.ResourceIsDisabled.selector);
        doSettle(rid, NULLIFIER);

        vm.prank(OWNER);
        registry.setDisabled(rid, false);
        assertFalse(registry.isDisabled(rid));
        doRegister(rid, COMMITMENT, PRICE);
    }

    function test_admin_can_disable_any_resource() public {
        vm.prank(ADMIN);
        registry.setDisabled(rid, true);
        assertTrue(registry.isDisabled(rid));
    }

    function test_stranger_cannot_disable() public {
        address[3] memory others = [STRANGER, BUYER, ATTACKER];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(SettlementRegistry.NotResourceOwner.selector);
            registry.setDisabled(rid, true);
        }
        assertFalse(registry.isDisabled(rid));
    }

    /// With no admin configured, nobody but the owner can take a resource down —
    /// and a zero-address caller must not slip through the admin check.
    function test_a_registry_without_an_admin_has_no_takedown_authority() public {
        SettlementRegistry adminless = new SettlementRegistry(address(usdc), address(semaphore), address(0));
        vm.prank(OWNER);
        bytes32 r = adminless.createResource(UID, PRICE, "");

        vm.prank(address(0));
        vm.expectRevert(SettlementRegistry.NotResourceOwner.selector);
        adminless.setDisabled(r, true);

        vm.prank(OWNER);
        adminless.setDisabled(r, true);
        assertTrue(adminless.isDisabled(r));
    }

    /// A settlement already made is a historical fact. Stopping the buyer from
    /// fetching the bytes is the access gate's job, not the chain's.
    function test_disabling_does_not_revoke_an_existing_settlement() public {
        doSettle(rid, NULLIFIER);
        vm.prank(ADMIN);
        registry.setDisabled(rid, true);
        assertTrue(registry.isSettled(STEALTH, rid));
    }

    function test_set_disabled_fails_if_not_found() public {
        vm.prank(ADMIN);
        vm.expectRevert(SettlementRegistry.ResourceNotFound.selector);
        registry.setDisabled(idOf(OWNER, UID2), true);
    }

    // ── price / hooks / misc ──────────────────────────────────────────────────

    function test_update_price_owner_only() public {
        address[3] memory others = [STRANGER, ADMIN, BUYER];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(SettlementRegistry.NotResourceOwner.selector);
            registry.updatePrice(rid, 5);
        }
        assertEq(registry.getPrice(rid), PRICE);

        vm.prank(OWNER);
        registry.updatePrice(rid, 5);
        assertEq(registry.getPrice(rid), 5);
    }

    /// A price change takes effect immediately, so an authorization signed for the
    /// old price reverts rather than under- or over-paying.
    function test_a_reprice_invalidates_an_in_flight_authorization() public {
        vm.prank(OWNER);
        registry.updatePrice(rid, PRICE * 2);

        vm.expectRevert(SettlementRegistry.IncorrectPaymentAmount.selector);
        doRegister(rid, COMMITMENT, PRICE);
        doRegister(rid, COMMITMENT, PRICE * 2);
    }

    function test_update_price_fails_if_not_found() public {
        vm.prank(OWNER);
        vm.expectRevert(SettlementRegistry.ResourceNotFound.selector);
        registry.updatePrice(idOf(OWNER, UID2), 500);
    }

    function test_register_hook_owner_only() public {
        vm.prank(STRANGER);
        vm.expectRevert(SettlementRegistry.NotResourceOwner.selector);
        registry.registerHook(rid, address(hook));

        vm.prank(OWNER);
        registry.registerHook(rid, address(hook));
    }

    function test_register_hook_fails_if_not_found() public {
        vm.prank(OWNER);
        vm.expectRevert(SettlementRegistry.ResourceNotFound.selector);
        registry.registerHook(idOf(OWNER, UID2), address(hook));
    }

    function test_unknown_resource_reads_are_zero() public view {
        bytes32 unknown = idOf(OWNER, UID2);
        assertEq(registry.getOwner(unknown), address(0));
        assertEq(registry.getPrice(unknown), 0);
        assertEq(registry.getUri(unknown), "");
        assertEq(registry.getGroupId(unknown), 0);
        assertFalse(registry.isDisabled(unknown));
        assertFalse(registry.isSettled(STEALTH, unknown));
        assertFalse(registry.isRegistered(unknown, 1));
    }
}
