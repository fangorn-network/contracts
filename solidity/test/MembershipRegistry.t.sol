// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    MembershipRegistry, IERC4907, IERC5192, IERC5643
} from "../src/MembershipRegistry.sol";
import {MockUSDC, MockSemaphore} from "./Mocks.sol";

/// The AppRegistry, as far as the MembershipRegistry can see it: who owns an app.
contract OwnerOnly {
    mapping(bytes32 => address) public getAppOwner;

    function set(bytes32 app, address owner) external {
        getAppOwner[app] = owner;
    }
}

contract MembershipRegistryTest is Test {
    MembershipRegistry reg;
    MockUSDC usdc;
    MockSemaphore sem;
    OwnerOnly apps;

    bytes32 constant APP = keccak256("quorum");
    address constant OWNER = address(0xA11CE);
    address constant PAYER = address(0xB0B);
    address constant ADMIN = address(0xAD);
    uint256 constant PRICE = 5_000_000;
    uint64 constant PERIOD = 30 days;
    uint256 constant COMMIT = 1234;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        sem = new MockSemaphore();
        apps = new OwnerOnly();
        apps.set(APP, OWNER);
        bytes memory init = abi.encodeCall(MembershipRegistry.initialize, (ADMIN, address(usdc), address(sem), address(apps)));
        reg = MembershipRegistry(address(new ERC1967Proxy(address(new MembershipRegistry()), init)));
        vm.prank(OWNER);
        reg.setPlan(APP, PRICE, PERIOD);
    }

    function pay(uint256 commitment, bytes32 salt) internal view returns (MembershipRegistry.Payment memory) {
        bytes32 nonce = reg.joinNonce(APP, reg.currentEpoch(APP), commitment, salt);
        return MembershipRegistry.Payment(PAYER, PRICE, 0, block.timestamp + 1 hours, nonce, 27, bytes32(0), bytes32(0));
    }

    function join(uint256 commitment) internal {
        reg.join(APP, commitment, bytes32(commitment), pay(commitment, bytes32(commitment)));
    }

    function claim(address holder, uint256 nullifier) internal returns (uint256) {
        uint256[8] memory points;
        return reg.claim(APP, block.timestamp / PERIOD, holder, 20, 99, nullifier, points);   // no call before claim: expectRevert would catch it
    }

    // ── plans ──

    function test_setPlan_onlyAppOwner() public {
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.setPlan(APP, 1, 1);
        (uint256 price, uint64 period) = reg.planOf(APP);
        assertEq(price, PRICE);
        assertEq(period, PERIOD);
    }

    function test_setPlan_priceNeedsAPeriod() public {
        vm.prank(OWNER);
        vm.expectRevert(MembershipRegistry.NoPlan.selector);
        reg.setPlan(APP, PRICE, 0);
    }

    function test_currentEpoch_noPlan() public {
        vm.expectRevert(MembershipRegistry.NoPlan.selector);
        reg.currentEpoch(keccak256("none"));
    }

    // ── join ──

    function test_join_paysOwnerAndAddsMember() public {
        join(COMMIT);
        assertEq(usdc.lastFrom(), address(reg), "the owner is paid from the registry");
        assertEq(usdc.lastTo(), OWNER);
        assertEq(usdc.lastAmount(), PRICE);
        assertEq(sem.lastAddCommitment(), COMMIT);
        assertEq(sem.lastAddGroup(), reg.groupOf(APP, reg.currentEpoch(APP)));
    }

    function test_join_reusesTheEpochsGroup() public {
        join(COMMIT);
        uint256 g = reg.groupOf(APP, reg.currentEpoch(APP));
        join(COMMIT + 1);
        assertEq(sem.lastAddGroup(), g);
        assertEq(sem.nextGroup(), g + 1, "one group per epoch");
    }

    function test_join_newEpochNewGroup() public {
        join(COMMIT);
        uint256 g = reg.groupOf(APP, reg.currentEpoch(APP));
        vm.warp(block.timestamp + PERIOD);
        join(COMMIT);
        assertTrue(reg.groupOf(APP, reg.currentEpoch(APP)) != g);
    }

    function test_join_wrongAmount() public {
        MembershipRegistry.Payment memory p = pay(COMMIT, "s");
        p.value = PRICE - 1;
        vm.expectRevert(MembershipRegistry.WrongAmount.selector);
        reg.join(APP, COMMIT, "s", p);
    }

    function test_join_nonceBindsTheCommitment() public {
        // Signed for COMMIT; a relayer swapping in its own commitment is refused.
        MembershipRegistry.Payment memory p = pay(COMMIT, "s");
        vm.expectRevert(MembershipRegistry.NonceNotBound.selector);
        reg.join(APP, COMMIT + 1, "s", p);
    }

    function test_join_noPlan() public {
        vm.prank(OWNER);
        reg.setPlan(APP, 0, 0);
        vm.expectRevert(MembershipRegistry.NoPlan.selector);
        reg.join(APP, COMMIT, "s", MembershipRegistry.Payment(PAYER, PRICE, 0, 0, 0, 0, 0, 0));
    }

    function test_join_signatureCannotBeFrontRunAtTheToken() public {
        MembershipRegistry.Payment memory p = pay(COMMIT, "s");
        vm.expectRevert("usdc: caller must be the payee");
        usdc.receiveWithAuthorization(p.from, address(reg), p.value, 0, p.validBefore, p.nonce, 27, 0, 0);
    }

    function test_join_paymentOnce() public {
        MembershipRegistry.Payment memory p = pay(COMMIT, "s");
        reg.join(APP, COMMIT, "s", p);
        vm.expectRevert("usdc: authorization used");
        reg.join(APP, COMMIT, "s", p);
    }

    // ── claim ──

    function test_claim_mintsLockedMembershipToHolder() public {
        join(COMMIT);
        address holder = address(0x5EA1);
        uint256 id = claim(holder, 777);
        assertEq(id, reg.tokenIdOf(APP, holder));
        assertEq(reg.ownerOf(id), holder);
        assertTrue(reg.locked(id));
        assertEq(reg.expiresAt(id), block.timestamp + PERIOD);
        assertEq(sem.lastProofMessage(), uint256(uint160(holder)), "the proof's message is the holder");
        assertEq(sem.lastProofScope(), reg.scopeOf(APP, reg.currentEpoch(APP)), "the scope is fixed by the registry");
        (bytes32 app, uint64 until) = reg.canRead(id, holder);
        assertEq(app, APP);
        assertEq(until, block.timestamp + PERIOD);
    }

    function test_claim_oncePerNullifier() public {
        join(COMMIT);
        claim(address(0x5EA1), 777);
        vm.expectRevert(MembershipRegistry.AlreadyClaimed.selector);
        claim(address(0x5EA1), 777);
    }

    function test_claim_needsAGroup() public {
        vm.expectRevert(MembershipRegistry.NoGroup.selector);
        claim(address(0x5EA1), 777);
    }

    function test_claim_noPlan() public {
        uint256[8] memory points;
        vm.expectRevert(MembershipRegistry.NoPlan.selector);
        reg.claim(keccak256("none"), 0, address(0x5EA1), 20, 99, 777, points);
    }

    function test_claim_badProof() public {
        join(COMMIT);
        sem.setFail(false, false, true);
        vm.expectRevert("semaphore: bad proof");
        claim(address(0x5EA1), 777);
    }

    function test_renewal_extendsFromExpiry_andFromNowAfterALapse() public {
        address holder = address(0x5EA1);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        uint64 first = reg.expiresAt(id);
        vm.warp(block.timestamp + 10 days);
        join(COMMIT + 1);
        claim(holder, 2);
        assertEq(reg.expiresAt(id), first + PERIOD, "renewing early stacks");
        vm.warp(block.timestamp + 200 days);
        join(COMMIT + 2);
        claim(holder, 3);
        assertEq(reg.expiresAt(id), block.timestamp + PERIOD, "after a lapse, from now");
    }

    function test_lapsed_canReadNothing() public {
        address holder = address(0x5EA1);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        vm.warp(block.timestamp + PERIOD + 1);
        (, uint64 until) = reg.canRead(id, holder);
        assertLt(until, block.timestamp);
    }

    function test_canRead_nothingForUnmintedOrZero() public {
        address holder = address(0x5EA1);
        (, uint64 unminted) = reg.canRead(reg.tokenIdOf(APP, holder), holder);
        assertEq(unminted, 0);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        (bytes32 app, uint64 zero) = reg.canRead(id, address(0));
        assertEq(app, APP);
        assertEq(zero, 0);
        assertEq(reg.appOfToken(id), APP);
    }

    // ── ERC-5643 ──

    function test_renewable_followsThePlan() public {
        join(COMMIT);
        uint256 id = claim(address(0x5EA1), 1);
        assertTrue(reg.isRenewable(id));
        vm.prank(OWNER);
        reg.setPlan(APP, 0, PERIOD);
        assertFalse(reg.isRenewable(id));
    }

    function test_renewAndCancel_pointToJoinAndClaim() public {
        vm.expectRevert(MembershipRegistry.UseJoinAndClaim.selector);
        reg.renewSubscription(1, PERIOD);
        vm.expectRevert(MembershipRegistry.UseJoinAndClaim.selector);
        reg.cancelSubscription(1);
    }

    // ── locked ──

    function test_notTransferable() public {
        address holder = address(0x5EA1);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        vm.prank(holder);
        vm.expectRevert(MembershipRegistry.NotTransferable.selector);
        reg.transferFrom(holder, address(0xBEEF), id);
    }

    // ── the agent (ERC-4907) ──

    function test_setUser_clampedToMembership() public {
        address holder = address(0x5EA1);
        address agent = address(0xA6E);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        vm.prank(holder);
        reg.setUser(id, agent, uint64(block.timestamp + 365 days));
        assertEq(reg.userOf(id), agent);
        assertEq(reg.userExpires(id), reg.expiresAt(id), "never past the membership");
        (, uint64 until) = reg.canRead(id, agent);
        assertEq(until, reg.expiresAt(id));
        (, uint64 none) = reg.canRead(id, address(0xBAD));
        assertEq(none, 0);
        vm.prank(agent);
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.setUser(id, agent, 1);
    }

    function test_setUserBySig() public {
        (address holder, uint256 key) = makeAddrAndKey("holder");
        address agent = address(0xA6E);
        join(COMMIT);
        uint256 id = claim(holder, 1);
        uint64 exp = uint64(block.timestamp + 7 days);
        uint256 deadline = block.timestamp + 1 hours;
        bytes memory sig = signSetUser(key, id, agent, exp, 0, deadline);
        reg.setUserBySig(id, agent, exp, deadline, sig);
        assertEq(reg.userOf(id), agent);
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.setUserBySig(id, agent, exp, deadline, sig); // replay: the nonce moved on
        bytes memory late = signSetUser(key, id, agent, exp, 1, deadline);
        vm.warp(deadline + 1);
        vm.expectRevert(MembershipRegistry.Expired.selector);
        reg.setUserBySig(id, agent, exp, deadline, late);
    }

    function signSetUser(uint256 key, uint256 id, address user, uint64 exp, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typehash = keccak256("SetUser(uint256 tokenId,address user,uint64 expires,uint256 nonce,uint256 deadline)");
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Fangorn Membership"),
                keccak256("1"),
                block.chainid,
                address(reg)
            )
        );
        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", domain, keccak256(abi.encode(typehash, id, user, exp, nonce, deadline)))
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // ── standards, admin ──

    function test_supportsInterfaces() public view {
        assertTrue(reg.supportsInterface(type(IERC4907).interfaceId));
        assertTrue(reg.supportsInterface(type(IERC5192).interfaceId));
        assertTrue(reg.supportsInterface(type(IERC5643).interfaceId));
        assertTrue(reg.supportsInterface(0x80ac58cd)); // ERC-721
        assertEq(reg.name(), "Fangorn Membership");
        assertEq(reg.symbol(), "FMEMBER");
    }

    function test_setAdmin_onlyAdmin_andHandsOverUpgrades() public {
        address next = address(0xAD2);
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.setAdmin(next);
        vm.prank(ADMIN);
        reg.setAdmin(next);
        assertEq(reg.admin(), next);
        address impl = address(new MembershipRegistry());
        vm.prank(ADMIN);
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.upgradeToAndCall(impl, "");
        vm.prank(next);
        reg.upgradeToAndCall(impl, "");
    }

    function test_upgrade_onlyAdmin() public {
        address impl = address(new MembershipRegistry());
        vm.expectRevert(MembershipRegistry.Unauthorized.selector);
        reg.upgradeToAndCall(impl, "");
        vm.prank(ADMIN);
        reg.upgradeToAndCall(impl, "");
    }
}
