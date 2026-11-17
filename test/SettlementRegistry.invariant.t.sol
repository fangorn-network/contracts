// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {SettlementRegistry} from "../src/SettlementRegistry.sol";
import {MockUSDC} from "./Mocks.sol";

/// Semaphore v4's checks that matter to the registry, with a toy "proof": `points[0]` is
/// the prover's commitment and `points[1]` the message, and the nullifier must be
/// H(scope, commitment), as Poseidon(scope, secret) is. Groups have an admin, reject zero
/// and duplicate leaves (LeanIMT), and each group spends a nullifier once.
contract StrictSemaphore {
    struct SemaphoreProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }

    uint256 public groupCount;
    mapping(uint256 => address) public adminOf;
    mapping(uint256 => mapping(uint256 => bool)) public isMember;
    mapping(uint256 => uint256) public size;
    mapping(uint256 => mapping(uint256 => bool)) public spent;

    function nullifierOf(uint256 scope, uint256 commitment) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(scope, commitment)));
    }

    function createGroup() external returns (uint256 id) {
        id = groupCount++;
        adminOf[id] = msg.sender;
    }

    function addMember(uint256 g, uint256 c) external {
        require(msg.sender == adminOf[g] && g < groupCount, "not admin");
        require(c != 0 && !isMember[g][c], "bad leaf");
        isMember[g][c] = true;
        size[g]++;
    }

    function validateProof(uint256 g, SemaphoreProof calldata p) external {
        require(g < groupCount && size[g] != 0, "no group");
        require(!spent[g][p.nullifier], "nullifier spent");
        require(isMember[g][p.points[0]] && p.points[1] == p.message, "bad proof");
        require(p.nullifier == nullifierOf(p.scope, p.points[0]), "bad nullifier");
        spent[g][p.nullifier] = true;
    }
}

contract SettlementHandler is Test {
    SettlementRegistry public reg;
    MockUSDC public usdc;
    StrictSemaphore public sem;
    address public constant ADMIN = address(0xAD);
    bytes32 public constant REPO = keccak256("photos");
    bytes32 public constant KEY = keccak256("photos/tabby.jpg");

    address[2] public pubs;
    uint256[2] internal pkeys;
    address[2] public refs = [address(0xC1), address(0xC2)];
    address[3] public readers = [address(0xD1), address(0xD2), address(0xD3)];
    address constant PAYER = address(0xB0B);

    uint256 public totalPaid;
    mapping(bytes32 => uint256[]) internal ghostMembers;
    mapping(bytes32 => uint256) public settles;
    string public violation;

    constructor(SettlementRegistry reg_, MockUSDC usdc_, StrictSemaphore sem_) {
        (reg, usdc, sem) = (reg_, usdc_, sem_);
        for (uint256 i; i < 2; i++) {
            (pubs[i], pkeys[i]) = makeAddrAndKey(string.concat("pub", vm.toString(i)));
        }
    }

    function subject(uint256 i) public view returns (bytes32) {
        return reg.subjectOf(pubs[i / 2], REPO, i % 2 == 0 ? bytes32(0) : KEY);
    }

    function memberCount(bytes32 s) external view returns (uint256) {
        return ghostMembers[s].length;
    }

    // ── actions ──

    struct R {
        uint256 p;
        bool whole;
        uint256 price;
        uint16 share;
        address referrer;
        uint256 commitment;
        int8 genShift;
        bool expired;
        uint8 tamper;
        bool ok;
        uint256 cut;
    }

    function register(uint256 p, uint256 priceSeed, uint16 share, uint8 refSeed, uint256 commitment, uint8 flags)
        external
    {
        R memory x;
        x.p = bound(p, 0, 1);
        x.whole = flags & 1 != 0;
        x.price = priceSeed % 3 == 0 ? 0 : bound(priceSeed, 1, 1e12);
        x.share = uint16(bound(share, 0, 11_000));
        uint8 rs = refSeed % 4;
        x.referrer = rs == 0 ? address(0) : rs == 1 ? pubs[x.p] : refs[rs - 2];
        x.commitment = bound(commitment, 1, 40); // small: repeats hit AlreadyRegistered
        x.genShift = flags & 6 == 2 ? int8(1) : flags & 6 == 4 ? -1 : int8(0);
        x.expired = flags & 24 == 24;
        x.tamper = (flags >> 5) % 4; // 1: wrong value, 2: unbound nonce, else none
        _register(x);
    }

    function _register(R memory x) internal {
        SettlementRegistry.Terms memory t;
        t.publisher = pubs[x.p];
        t.repo = REPO;
        t.key = x.whole ? bytes32(0) : KEY;
        t.price = x.price;
        t.shareBps = x.share;
        uint64 g = reg.generationOf(t.publisher, REPO);
        if (x.genShift < 0 && g == 0) x.genShift = 1;
        t.generation = x.genShift > 0 ? g + 1 : x.genShift < 0 ? g - 1 : g;
        t.deadline = x.expired ? uint64(block.timestamp - 1) : uint64(block.timestamp + 1 days);
        bytes memory sig = _sign(x.p, t);
        bytes32 subj = reg.subjectOf(t.publisher, REPO, t.key);
        SettlementRegistry.Payment memory pay;
        pay.from = PAYER;
        pay.value = x.tamper == 1 ? x.price + 1 : x.price;
        pay.nonce = reg.registerNonce(subj, x.commitment, x.referrer, x.tamper == 2 ? bytes32("other") : bytes32(0));
        if (x.tamper == 2) pay.nonce = keccak256(abi.encode(pay.nonce));

        x.ok = !x.expired && x.genShift == 0 && x.share <= 10_000 && !reg.isDisabled(subj)
            && !reg.isDisabled(reg.subjectOf(t.publisher, REPO, 0)) && !reg.isRegistered(subj, x.commitment)
            && (x.price == 0 || (x.tamper != 1 && x.tamper != 2));
        x.cut = x.referrer != address(0) && x.referrer != t.publisher && !reg.isDenied(t.publisher, x.referrer)
            ? x.price * x.share / 10_000
            : 0;

        uint256 pubBefore = usdc.balanceOf(t.publisher);
        uint256 refBefore = x.referrer == address(0) ? 0 : usdc.balanceOf(x.referrer);
        try reg.register(t, sig, x.commitment, x.referrer, bytes32(0), pay) {
            if (!x.ok) return _fail("invalid registration accepted");
        } catch {
            if (x.ok) _fail("valid registration rejected");
            return;
        }
        totalPaid += x.price;
        ghostMembers[subj].push(x.commitment);
        if (usdc.balanceOf(t.publisher) - pubBefore != x.price - x.cut) _fail("publisher paid wrong amount");
        if (x.referrer != address(0) && x.referrer != t.publisher && usdc.balanceOf(x.referrer) - refBefore != x.cut) {
            _fail("referrer paid wrong amount");
        }
    }

    function _sign(uint256 p, SettlementRegistry.Terms memory t) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pkeys[p], reg.hashTerms(t));
        return abi.encodePacked(r, s, v);
    }

    /// kind 0: an honest proof; 1: a commitment not in the group; 2: a wrong nullifier.
    function settle(uint256 si, uint256 mi, uint256 ri, uint8 kind) external {
        bytes32 s = subject(bound(si, 0, 3));
        address reader = readers[bound(ri, 0, 2)];
        uint256[] storage m = ghostMembers[s];
        uint256 c = m.length == 0 ? 1 : m[bound(mi, 0, m.length - 1)];
        kind %= 3;
        if (kind == 1) c = 1000 + mi % 1000;
        uint256 nullifier = sem.nullifierOf(uint256(s), c);
        if (kind == 2) nullifier ^= 1;

        bool ok = kind == 0 && m.length != 0 && !reg.isDisabled(s) && !_spent(s, nullifier);
        if (_settle(s, reader, c, nullifier) != ok) {
            return _fail(ok ? "valid settle rejected" : "invalid settle accepted");
        }
        if (!ok) return;
        settles[s]++;
        // One settle per payment: the same commitment, for any reader, is spent.
        if (_settle(s, readers[(bound(ri, 0, 2) + 1) % 3], c, nullifier)) _fail("nullifier reused");
    }

    function _spent(bytes32 s, uint256 nullifier) internal view returns (bool) {
        try reg.groupOf(s) returns (uint256 g) {
            return sem.spent(g, nullifier);
        } catch {
            return false;
        }
    }

    function _settle(bytes32 s, address reader, uint256 c, uint256 nullifier) internal returns (bool) {
        uint256[8] memory points;
        points[0] = c;
        points[1] = uint256(uint160(reader));
        try reg.settle(s, reader, 20, 0, nullifier, points) {
            return true;
        } catch {
            return false;
        }
    }

    function raiseGeneration(uint256 p) external {
        vm.prank(pubs[bound(p, 0, 1)]);
        reg.raiseGeneration(REPO);
    }

    function setDenied(uint256 p, uint256 r, bool denied) external {
        vm.prank(pubs[bound(p, 0, 1)]);
        reg.setDenied(refs[bound(r, 0, 1)], denied);
    }

    /// who 0: the publisher, 1: the admin, 2: anyone else (must fail)
    function setDisabled(uint256 si, uint8 who, bool disabled) external {
        si = bound(si, 0, 3);
        address pub = pubs[si / 2];
        who %= 3;
        vm.prank(who == 0 ? pub : who == 1 ? ADMIN : address(0xBAD));
        try reg.setDisabled(pub, REPO, si % 2 == 0 ? bytes32(0) : KEY, disabled) {
            if (who == 2) _fail("stranger disabled a subject");
        } catch {
            if (who != 2) _fail("publisher or admin could not disable");
        }
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 2 days));
    }

    function _fail(string memory why) internal {
        if (bytes(violation).length == 0) violation = why;
    }
}

/// Stateful properties of the SettlementRegistry. Runs/depth in foundry.toml [invariant].
contract SettlementRegistryInvariantTest is Test {
    SettlementRegistry reg;
    MockUSDC usdc;
    SettlementHandler h;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        StrictSemaphore sem = new StrictSemaphore();
        bytes memory init = abi.encodeCall(SettlementRegistry.initialize, (address(0xAD), address(usdc), address(sem)));
        reg = SettlementRegistry(address(new ERC1967Proxy(address(new SettlementRegistry()), init)));
        h = new SettlementHandler(reg, usdc, sem);
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](6);
        sel[0] = SettlementHandler.register.selector;
        sel[1] = SettlementHandler.settle.selector;
        sel[2] = SettlementHandler.raiseGeneration.selector;
        sel[3] = SettlementHandler.setDenied.selector;
        sel[4] = SettlementHandler.setDisabled.selector;
        sel[5] = SettlementHandler.warp.selector;
        targetSelector(FuzzSelector(address(h), sel));
    }

    /// Covers: stale generation, expired terms, shareBps > 10000, wrong amount, unbound
    /// nonce, disabled subjects, duplicate commitments and forged/replayed proofs are always
    /// rejected; exact publisher/referrer split per registration.
    function invariant_every_outcome_matches_the_model() public view {
        assertEq(h.violation(), "");
    }

    function invariant_registry_holds_no_usdc() public view {
        assertEq(usdc.balanceOf(address(reg)), 0);
    }

    /// Everything paid in went to publishers and referrers.
    function invariant_usdc_is_conserved() public view {
        uint256 sum;
        for (uint256 i; i < 2; i++) {
            sum += usdc.balanceOf(h.pubs(i)) + usdc.balanceOf(h.refs(i));
        }
        assertEq(sum, h.totalPaid());
    }

    /// No settle without a registration, and at most one per registered commitment.
    function invariant_settles_bounded_by_registrations() public view {
        for (uint256 i; i < 4; i++) {
            bytes32 s = h.subject(i);
            uint256 n = h.memberCount(s);
            assertLe(h.settles(s), n);
            if (n == 0) {
                for (uint256 r; r < 3; r++) {
                    assertFalse(reg.isSettled(h.readers(r), s));
                }
            } else {
                assertEq(reg.membersOf(s).length, n);
            }
        }
    }

    /// canRead is exactly: settled for the record or the whole repo, and neither disabled.
    function invariant_canRead_definition() public view {
        for (uint256 p; p < 2; p++) {
            address pub = h.pubs(p);
            bytes32 whole = reg.subjectOf(pub, h.REPO(), 0);
            bytes32 one = reg.subjectOf(pub, h.REPO(), h.KEY());
            for (uint256 r; r < 3; r++) {
                address reader = h.readers(r);
                bool want = !reg.isDisabled(whole) && !reg.isDisabled(one)
                    && (reg.isSettled(reader, whole) || reg.isSettled(reader, one));
                assertEq(reg.canRead(reader, pub, h.REPO(), h.KEY()), want);
            }
        }
    }
}

/// Stateless fuzz on register's checks.
contract SettlementRegistryFuzzTest is Test {
    SettlementRegistry reg;
    MockUSDC usdc;
    address pub;
    uint256 pk;

    function setUp() public {
        vm.warp(1_800_000_000);
        (pub, pk) = makeAddrAndKey("pub");
        usdc = new MockUSDC();
        StrictSemaphore sem = new StrictSemaphore();
        bytes memory init = abi.encodeCall(SettlementRegistry.initialize, (address(0xAD), address(usdc), address(sem)));
        reg = SettlementRegistry(address(new ERC1967Proxy(address(new SettlementRegistry()), init)));
    }

    function _buy(uint256 price, uint16 share, uint64 generation, address referrer) internal returns (bool) {
        SettlementRegistry.Terms memory t =
            SettlementRegistry.Terms(pub, keccak256("r"), 0, price, share, generation, uint64(block.timestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, reg.hashTerms(t));
        bytes32 nonce = reg.registerNonce(reg.subjectOf(pub, t.repo, 0), 7, referrer, 0);
        SettlementRegistry.Payment memory p = SettlementRegistry.Payment(address(0xB0B), price, 0, 0, nonce, 0, 0, 0);
        try reg.register(t, abi.encodePacked(r, s, v), 7, referrer, 0, p) {
            return true;
        } catch {
            return false;
        }
    }

    /// Split is exact for any price and share; the registry keeps nothing; >100% refused.
    function testFuzz_split_is_exact(uint256 price, uint16 share) public {
        price = bound(price, 1, type(uint256).max / 10_000);
        bool ok = _buy(price, share, 0, address(0xC1));
        assertEq(ok, share <= 10_000);
        if (!ok) return;
        uint256 cut = usdc.balanceOf(address(0xC1));
        assertEq(cut, price * share / 10_000);
        assertEq(usdc.balanceOf(pub) + cut, price);
        assertEq(usdc.balanceOf(address(reg)), 0);
    }

    /// Terms signed for any generation but the current one are void.
    function testFuzz_stale_generation_rejected(uint8 raises, uint64 signedFor) public {
        for (uint256 i; i < raises % 8; i++) {
            vm.prank(pub);
            reg.raiseGeneration(keccak256("r"));
        }
        assertEq(_buy(1e6, 0, signedFor, address(0)), signedFor == raises % 8);
    }

    /// membersOf reads one cold slot per buyer, so its gas grows ~2.1k per member. A node's
    /// eth_call gas cap (geth's default --rpc.gascap is 50M) is reached at roughly 23k
    /// members: past that, buyers cannot read the group from the chain in one call. A free
    /// subject's terms let anyone add members for the gas alone.
    function test_membersOf_gas_grows_per_member() public {
        SettlementRegistry.Terms memory t =
            SettlementRegistry.Terms(pub, keccak256("r"), 0, 0, 0, 0, uint64(block.timestamp));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, reg.hashTerms(t));
        bytes memory sig = abi.encodePacked(r, s, v);
        SettlementRegistry.Payment memory none;
        bytes32 subj;
        uint256 n = 500;
        for (uint256 i = 1; i <= n; i++) {
            subj = reg.register(t, sig, i, address(0), 0, none); // anyone, no payment
        }
        vm.cool(address(reg));
        uint256 g = gasleft();
        assertEq(reg.membersOf(subj).length, n);
        uint256 perMember = (g - gasleft()) / n;
        emit log_named_uint("membersOf gas per member", perMember);
        emit log_named_uint("members at a 50M eth_call cap", 50_000_000 / perMember);
        assertGt(perMember, 2_100);
        assertLt(50_000_000 / perMember, 25_000);
    }

    function _settle(bytes32 subj, address reader, uint256 commitment) internal {
        uint256[8] memory points;
        points[0] = commitment;
        points[1] = uint256(uint160(reader));
        StrictSemaphore sem = StrictSemaphore(reg.semaphore());
        reg.settle(subj, reader, 20, 0, sem.nullifierOf(uint256(subj), commitment), points);
    }

    /// Design question, pinned: access is not per generation. A registration made under
    /// generation 0 still settles after the publisher raises the generation, and a reader
    /// settled before the raise keeps canRead after it. A key server that releases the
    /// current generation's key on canRead alone gives old buyers every later generation.
    function test_generation_raise_does_not_revoke_access() public {
        bytes32 repo = keccak256("r");
        bytes32 subj = reg.subjectOf(pub, repo, 0);
        assertTrue(_buy(1e6, 0, 0, address(0))); // commitment 7, generation 0
        vm.prank(pub);
        reg.raiseGeneration(repo);
        assertFalse(_buy(1e6, 0, 0, address(0)), "old terms are void");
        _settle(subj, address(0xD1), 7); // ...but the old registration still settles
        assertTrue(reg.canRead(address(0xD1), pub, repo, keccak256("any record")));
    }

    /// Low, pinned: naming the registry itself as referrer strands the cut in the registry
    /// (no function moves USDC out). Only the payer's own signed nonce can name it.
    function test_registry_as_referrer_strands_the_cut() public {
        assertTrue(_buy(1e6, 2_000, 0, address(reg)));
        assertEq(usdc.balanceOf(address(reg)), 200_000);
    }
}
