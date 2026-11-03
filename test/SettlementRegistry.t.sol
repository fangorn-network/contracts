// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {SettlementRegistry} from "../src/SettlementRegistry.sol";
import {MockUSDC, MockSemaphore} from "./Mocks.sol";

/// An ERC-1271 wallet that accepts one digest.
contract MockWallet {
    bytes32 public approved;

    function approve(bytes32 digest) external {
        approved = digest;
    }

    function isValidSignature(bytes32 digest, bytes calldata) external view returns (bytes4) {
        return digest == approved ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

contract SettlementRegistryTest is Test {
    SettlementRegistry reg;
    MockUSDC usdc;
    MockSemaphore sem;

    address publisher;
    uint256 publisherKey;
    address constant PAYER = address(0xB0B);
    address constant REFERRER = address(0xC0FFEE);
    address constant READER = address(0xDEAD);
    address constant ADMIN = address(0xAD);

    bytes32 constant REPO = keccak256("photos");
    bytes32 constant KEY = keccak256("photos/tabby.jpg");
    uint256 constant PRICE = 1_000_000;
    uint16 constant SHARE = 2_000;
    uint256 constant COMMIT = 1234;

    function setUp() public {
        vm.warp(1_800_000_000);
        (publisher, publisherKey) = makeAddrAndKey("publisher");
        usdc = new MockUSDC();
        sem = new MockSemaphore();
        bytes memory init = abi.encodeCall(SettlementRegistry.initialize, (ADMIN, address(usdc), address(sem)));
        reg = SettlementRegistry(address(new ERC1967Proxy(address(new SettlementRegistry()), init)));
    }

    // ── helpers ──

    function terms(bytes32 key, uint256 price, uint16 share) internal view returns (SettlementRegistry.Terms memory) {
        return SettlementRegistry.Terms(publisher, REPO, key, price, share, 0, uint64(block.timestamp + 1 days));
    }

    function sign(SettlementRegistry.Terms memory t, uint256 pk) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, reg.hashTerms(t));
        return abi.encodePacked(r, s, v);
    }

    function pay(SettlementRegistry.Terms memory t, uint256 commitment, address referrer)
        internal
        view
        returns (SettlementRegistry.Payment memory)
    {
        bytes32 subject = reg.subjectOf(t.publisher, t.repo, t.key);
        bytes32 nonce = reg.registerNonce(subject, commitment, referrer, bytes32(commitment));
        return SettlementRegistry.Payment(PAYER, t.price, 0, block.timestamp + 1 hours, nonce, 27, 0, 0);
    }

    function buy(SettlementRegistry.Terms memory t, uint256 commitment, address referrer) internal returns (bytes32) {
        return
            reg.register(
                t, sign(t, publisherKey), commitment, referrer, bytes32(commitment), pay(t, commitment, referrer)
            );
    }

    function settle(bytes32 subject, address reader, uint256 nullifier) internal {
        uint256[8] memory points;
        reg.settle(subject, reader, 20, 99, nullifier, points);
    }

    // ── register: payment ──

    function test_register_paysPublisherWithoutReferrer() public {
        bytes32 subject = buy(terms(KEY, PRICE, SHARE), COMMIT, address(0));
        assertEq(usdc.balanceOf(publisher), PRICE);
        assertEq(usdc.balanceOf(address(reg)), 0);
        assertTrue(reg.isRegistered(subject, COMMIT));
        assertEq(sem.lastAddCommitment(), COMMIT);
        assertEq(sem.lastAddGroup(), reg.groupOf(subject));
    }

    function test_register_splitsWithReferrer() public {
        vm.expectEmit(true, true, true, true);
        emit SettlementRegistry.Registered(
            reg.subjectOf(publisher, REPO, KEY), publisher, REFERRER, COMMIT, PRICE, 200_000
        );
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), 200_000);
        assertEq(usdc.balanceOf(publisher), 800_000);
        assertEq(usdc.balanceOf(address(reg)), 0);
    }

    function test_register_deniedReferrerGetsNothing() public {
        vm.prank(publisher);
        reg.setDenied(REFERRER, true);
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), 0);
        assertEq(usdc.balanceOf(publisher), PRICE);
    }

    function test_register_liftedDenialPaysAgain() public {
        vm.startPrank(publisher);
        reg.setDenied(REFERRER, true);
        reg.setDenied(REFERRER, false);
        vm.stopPrank();
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), 200_000);
    }

    function test_register_denialIsPerPublisher() public {
        vm.prank(address(0xBAD));
        reg.setDenied(REFERRER, true);
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), 200_000);
    }

    function test_register_publisherAsReferrerTakesWholePrice() public {
        buy(terms(KEY, PRICE, SHARE), COMMIT, publisher);
        assertEq(usdc.balanceOf(publisher), PRICE);
    }

    function test_register_zeroShare() public {
        buy(terms(KEY, PRICE, 0), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), 0);
        assertEq(usdc.balanceOf(publisher), PRICE);
    }

    function test_register_fullShare() public {
        buy(terms(KEY, PRICE, 10_000), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER), PRICE);
        assertEq(usdc.balanceOf(publisher), 0);
    }

    function testFuzz_register_splitAddsUp(uint128 price, uint16 share) public {
        vm.assume(price != 0);
        share = uint16(bound(share, 0, 10_000));
        buy(terms(KEY, price, share), COMMIT, REFERRER);
        assertEq(usdc.balanceOf(REFERRER) + usdc.balanceOf(publisher), price);
        assertEq(usdc.balanceOf(REFERRER), uint256(price) * share / 10_000);
        assertEq(usdc.balanceOf(address(reg)), 0);
    }

    function test_register_freeSubjectMovesNoMoney() public {
        SettlementRegistry.Terms memory t = terms(KEY, 0, SHARE);
        SettlementRegistry.Payment memory none;
        bytes32 subject = reg.register(t, sign(t, publisherKey), COMMIT, REFERRER, 0, none);
        assertEq(usdc.calls(), 0);
        assertTrue(reg.isRegistered(subject, COMMIT));
    }

    function test_register_wrongAmount() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        p.value = PRICE - 1;
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.WrongAmount.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_relayerCannotSwapReferrer() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.NonceNotBound.selector);
        reg.register(t, sig, COMMIT, address(0xE7E), bytes32(COMMIT), p);
    }

    function test_register_relayerCannotSwapCommitment() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.NonceNotBound.selector);
        reg.register(t, sig, COMMIT + 1, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_paymentForOneSubjectCannotBuyAnother() public {
        SettlementRegistry.Terms memory paid = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Terms memory other = terms(keccak256("other"), PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(paid, COMMIT, REFERRER);
        bytes memory sig = sign(other, publisherKey);
        vm.expectRevert(SettlementRegistry.NonceNotBound.selector);
        reg.register(other, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_usdcRefusesRevertsEverything() public {
        usdc.setMode(MockUSDC.Mode.Revert);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert("usdc: refused");
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
        assertFalse(reg.isRegistered(reg.subjectOf(publisher, REPO, KEY), COMMIT));
        assertEq(sem.adds(), 0);
    }

    function test_register_usdcReturnsFalseReverts() public {
        usdc.setMode(MockUSDC.Mode.ReturnFalse);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert();
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    // ── register: terms ──

    function test_register_expiredTerms() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.warp(t.deadline + 1);
        vm.expectRevert(SettlementRegistry.Expired.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_termsValidAtDeadline() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.warp(t.deadline);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_raiseGeneration_voidsEarlierTerms() public {
        SettlementRegistry.Terms memory old = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(old, COMMIT, REFERRER);
        bytes memory sig = sign(old, publisherKey);
        vm.prank(publisher);
        assertEq(reg.raiseGeneration(REPO), 1);
        vm.expectRevert(SettlementRegistry.StaleTerms.selector);
        reg.register(old, sig, COMMIT, REFERRER, bytes32(COMMIT), p);

        SettlementRegistry.Terms memory fresh = old;
        fresh.price = 2 * PRICE;
        fresh.generation = 1;
        buy(fresh, COMMIT, REFERRER);
        assertEq(usdc.balanceOf(publisher) + usdc.balanceOf(REFERRER), 2 * PRICE);
    }

    function test_raiseGeneration_isPerRepoAndPublisher() public {
        vm.prank(publisher);
        reg.raiseGeneration(keccak256("videos"));
        vm.prank(address(0xBAD));
        reg.raiseGeneration(REPO);
        assertEq(reg.generationOf(publisher, REPO), 0);
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
    }

    function test_register_futureGenerationIsStale() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        t.generation = 1;
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.StaleTerms.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_shareOverWhole() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, 10_001);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.BadShare.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_termsSignedByAnotherKey() public {
        (, uint256 other) = makeAddrAndKey("impostor");
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, other);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_tamperedPrice() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        bytes memory sig = sign(t, publisherKey);
        t.price = 1;
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_tamperedShare() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        bytes memory sig = sign(t, publisherKey);
        t.shareBps = 10_000;
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_termsForOneRecordDontSellAnother() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        bytes memory sig = sign(t, publisherKey);
        t.key = keccak256("photos/other.jpg");
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_zeroPublisher() public {
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        t.publisher = address(0);
        bytes memory sig = sign(t, publisherKey);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_termsFromAnotherDeploymentRejected() public {
        bytes memory init = abi.encodeCall(SettlementRegistry.initialize, (ADMIN, address(usdc), address(sem)));
        SettlementRegistry other =
            SettlementRegistry(address(new ERC1967Proxy(address(new SettlementRegistry()), init)));
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(publisherKey, other.hashTerms(t));
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        vm.expectRevert(SettlementRegistry.BadSignature.selector);
        reg.register(t, abi.encodePacked(r, s, v), COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_contractPublisher() public {
        MockWallet wallet = new MockWallet();
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        t.publisher = address(wallet);
        wallet.approve(reg.hashTerms(t));
        reg.register(t, "", COMMIT, REFERRER, bytes32(COMMIT), pay(t, COMMIT, REFERRER));
        assertEq(usdc.balanceOf(address(wallet)), 800_000);
    }

    // ── register: subjects and groups ──

    function test_register_sameCommitmentTwice() public {
        buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, address(0));
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.AlreadyRegistered.selector);
        reg.register(t, sig, COMMIT, address(0), bytes32(COMMIT), p);
    }

    function test_register_oneGroupPerSubject() public {
        bytes32 a = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        bytes32 b = buy(terms(KEY, PRICE, SHARE), COMMIT + 1, REFERRER);
        bytes32 c = buy(terms(bytes32(0), PRICE, SHARE), COMMIT, REFERRER);
        assertEq(a, b);
        assertEq(reg.groupOf(a), reg.groupOf(b));
        assertTrue(reg.groupOf(a) != reg.groupOf(c));
        assertEq(sem.nextGroup(), 9);
        assertEq(sem.adds(), 3);
    }

    function test_membersOf_inTheOrderAddedPerSubject() public {
        bytes32 a = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        buy(terms(KEY, PRICE, SHARE), COMMIT + 1, REFERRER);
        bytes32 whole = buy(terms(bytes32(0), PRICE, SHARE), COMMIT + 2, REFERRER);
        uint256[] memory ma = reg.membersOf(a);
        assertEq(ma.length, 2);
        assertEq(ma[0], COMMIT);
        assertEq(ma[1], COMMIT + 1);
        uint256[] memory mw = reg.membersOf(whole);
        assertEq(mw.length, 1);
        assertEq(mw[0], COMMIT + 2);
        assertEq(sem.lastAddCommitment(), COMMIT + 2);
    }

    function test_membersOf_freeRegisterIsAMember() public {
        SettlementRegistry.Terms memory t = terms(KEY, 0, SHARE);
        SettlementRegistry.Payment memory none;
        bytes32 subject = reg.register(t, sign(t, publisherKey), COMMIT, REFERRER, 0, none);
        assertEq(reg.membersOf(subject).length, 1);
    }

    function test_membersOf_noneBeforeAnyRegister() public view {
        assertEq(reg.membersOf(reg.subjectOf(publisher, REPO, KEY)).length, 0);
    }

    function test_membersOf_failedRegisterAddsNoOne() public {
        sem.setFail(false, true, false);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert();
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
        assertEq(reg.membersOf(reg.subjectOf(publisher, REPO, KEY)).length, 0);
    }

    function test_register_recordsHaveTheirOwnPrices() public {
        buy(terms(KEY, PRICE, 0), COMMIT, address(0));
        buy(terms(keccak256("photos/rare.jpg"), 5 * PRICE, 0), COMMIT, address(0));
        assertEq(usdc.balanceOf(publisher), 6 * PRICE);
    }

    function test_register_semaphoreFailureReverts() public {
        sem.setFail(false, true, false);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert("semaphore: no member");
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
        assertEq(usdc.balanceOf(publisher), 0);
    }

    // ── disable ──

    function test_register_disabledRecord() public {
        vm.prank(publisher);
        reg.setDisabled(publisher, REPO, KEY, true);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.Disabled.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_register_disabledRepoBlocksItsRecords() public {
        vm.prank(ADMIN);
        reg.setDisabled(publisher, REPO, bytes32(0), true);
        SettlementRegistry.Terms memory t = terms(KEY, PRICE, SHARE);
        SettlementRegistry.Payment memory p = pay(t, COMMIT, REFERRER);
        bytes memory sig = sign(t, publisherKey);
        vm.expectRevert(SettlementRegistry.Disabled.selector);
        reg.register(t, sig, COMMIT, REFERRER, bytes32(COMMIT), p);
    }

    function test_setDisabled_onlyPublisherOrAdmin() public {
        vm.prank(REFERRER);
        vm.expectRevert(SettlementRegistry.Unauthorized.selector);
        reg.setDisabled(publisher, REPO, KEY, true);
        vm.prank(publisher);
        reg.setDisabled(publisher, REPO, KEY, true);
        vm.prank(ADMIN);
        reg.setDisabled(publisher, REPO, KEY, false);
        assertFalse(reg.isDisabled(reg.subjectOf(publisher, REPO, KEY)));
    }

    // ── settle ──

    function test_settle_marksReader() public {
        bytes32 subject = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        settle(subject, READER, 42);
        assertTrue(reg.isSettled(READER, subject));
        assertFalse(reg.isSettled(PAYER, subject));
        assertEq(sem.lastProofGroup(), reg.groupOf(subject));
        assertEq(sem.lastProofScope(), uint256(subject));
        assertEq(sem.lastProofMessage(), uint256(uint160(READER)));
        assertEq(sem.lastProofNullifier(), 42);
    }

    function test_settle_oncePerNullifier() public {
        bytes32 subject = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        settle(subject, READER, 42);
        uint256[8] memory points;
        vm.expectRevert(SettlementRegistry.AlreadySettled.selector);
        reg.settle(subject, address(0xF00), 20, 99, 42, points);
    }

    function test_settle_unsoldSubject() public {
        uint256[8] memory points;
        bytes32 subject = reg.subjectOf(publisher, REPO, KEY);
        vm.expectRevert(SettlementRegistry.NoGroup.selector);
        reg.settle(subject, READER, 20, 99, 42, points);
    }

    function test_settle_badProof() public {
        bytes32 subject = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        sem.setFail(false, false, true);
        uint256[8] memory points;
        vm.expectRevert("semaphore: bad proof");
        reg.settle(subject, READER, 20, 99, 42, points);
        assertFalse(reg.isSettled(READER, subject));
    }

    function test_settle_disabled() public {
        bytes32 subject = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        vm.prank(ADMIN);
        reg.setDisabled(publisher, REPO, KEY, true);
        uint256[8] memory points;
        vm.expectRevert(SettlementRegistry.Disabled.selector);
        reg.settle(subject, READER, 20, 99, 42, points);
    }

    // ── canRead ──

    function test_canRead_wholeRepoCoversEveryRecord() public {
        bytes32 whole = buy(terms(bytes32(0), PRICE, SHARE), COMMIT, REFERRER);
        settle(whole, READER, 1);
        assertTrue(reg.canRead(READER, publisher, REPO, KEY));
        assertTrue(reg.canRead(READER, publisher, REPO, keccak256("photos/other.jpg")));
        assertFalse(reg.canRead(READER, publisher, keccak256("videos"), KEY));
    }

    function test_canRead_recordCoversOnlyItself() public {
        bytes32 one = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        settle(one, READER, 1);
        assertTrue(reg.canRead(READER, publisher, REPO, KEY));
        assertFalse(reg.canRead(READER, publisher, REPO, keccak256("photos/other.jpg")));
        assertFalse(reg.canRead(READER, publisher, REPO, bytes32(0)));
    }

    function test_canRead_disablingRecordOrRepoRevokesAndRestores() public {
        bytes32 one = buy(terms(KEY, PRICE, SHARE), COMMIT, REFERRER);
        settle(one, READER, 1);
        vm.startPrank(ADMIN);
        reg.setDisabled(publisher, REPO, KEY, true);
        assertFalse(reg.canRead(READER, publisher, REPO, KEY));
        reg.setDisabled(publisher, REPO, KEY, false);
        reg.setDisabled(publisher, REPO, bytes32(0), true);
        assertFalse(reg.canRead(READER, publisher, REPO, KEY));
        reg.setDisabled(publisher, REPO, bytes32(0), false);
        vm.stopPrank();
        assertTrue(reg.canRead(READER, publisher, REPO, KEY));
    }

    function test_canRead_unsettledReader() public view {
        assertFalse(reg.canRead(READER, publisher, REPO, KEY));
    }

    // ── admin and proxy ──

    function test_setAdmin_onlyAdmin() public {
        vm.expectRevert(SettlementRegistry.Unauthorized.selector);
        reg.setAdmin(REFERRER);
        vm.prank(ADMIN);
        reg.setAdmin(REFERRER);
        assertEq(reg.admin(), REFERRER);
    }

    function test_upgrade_onlyAdmin() public {
        address next = address(new SettlementRegistry());
        vm.expectRevert(SettlementRegistry.Unauthorized.selector);
        UUPSUpgradeable(address(reg)).upgradeToAndCall(next, "");
        vm.prank(ADMIN);
        UUPSUpgradeable(address(reg)).upgradeToAndCall(next, "");
    }

    function test_initialize_once() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        reg.initialize(REFERRER, address(usdc), address(sem));
    }

    function test_implementation_locked() public {
        SettlementRegistry impl = new SettlementRegistry();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(ADMIN, address(usdc), address(sem));
    }
}
