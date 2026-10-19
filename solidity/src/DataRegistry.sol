// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// DataRegistry
///
/// The heads of every repo, and their update log (WHITEPAPER_1 §3.2, H and U).
///
/// A repo is `(publisher, repo)`: one publisher's data under a name it chooses. It
/// belongs to no app: any address may update its own repos, with a compare-and-swap on
/// the head, and an update names no app. Which apps present a repo is the AppRegistry's
/// (an app presents the publishers whose storage it provides, at their latest heads).
///
/// What is not here yet (docs/REGISTRY_SPEC.md in the SDK): the head is passed in, not
/// computed from the commit; the commit's epoch is not checked; the log is events, not
/// an MMR.
///
/// Deployed behind an ERC-1967 proxy (UUPS): the proxy holds the state and the address,
/// and the admin can point it at a new implementation. Storage is therefore
/// append-only: add state variables after the last one, and never reorder, retype or
/// remove what is there. A new version is an edit to this file; the upgrade tooling
/// checks its storage against the build of the live version, committed under
/// `deployed/`.
contract DataRegistry is Initializable, UUPSUpgradeable {
    error Unauthorized();
    error StaleStateRoot();
    /// A head is the name of a commit, never zero: zero is "never written".
    error ZeroHead();

    event AdminChanged(address previous_admin, address new_admin);
    /// `publisher` moved `repo` from `parent` to `head`, the repo's `pos`-th head.
    event Updated(
        address indexed publisher, bytes32 indexed repo_id, string repo, uint64 pos, bytes32 parent, bytes32 head
    );

    struct Head {
        uint64 pos;
        bytes32 head;
    }

    /// Protocol admin: upgrades, and repoints the AppRegistry
    address public admin;
    /// The AppRegistry this one was deployed with. Nothing here calls it any more; kept
    /// so that storage stays append-only.
    address public appRegistry;
    /// Retired: heads keyed by app, from when a repo lived under one app. Kept so that
    /// storage stays append-only.
    mapping(bytes32 => bytes32) internal namespaceHeads;
    /// publisher => keccak256(repo) => (position, head); (0, 0) for a repo never written
    mapping(address => mapping(bytes32 => Head)) internal heads;

    /// The implementation is only ever used through a proxy. Lock it, so nobody can
    /// initialize it directly.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// Takes the place of a constructor: runs once, in the proxy's storage, as part of
    /// the proxy's deployment.
    function initialize(address admin_, address appRegistry_) external initializer {
        admin = admin_;
        appRegistry = appRegistry_;
    }

    /// Move the sender's `repo` from `parent` to `head`. Reverts `StaleStateRoot` unless
    /// `parent` is the head.
    function update(string calldata repo, bytes32 parent, bytes32 head) external {
        if (head == bytes32(0)) revert ZeroHead();
        bytes32 repo_id = keccak256(bytes(repo));
        Head storage h = heads[msg.sender][repo_id];
        if (h.head != parent) revert StaleStateRoot();
        uint64 pos = h.pos + 1;
        h.pos = pos;
        h.head = head;
        emit Updated(msg.sender, repo_id, repo, pos, parent, head);
    }

    /// H(publisher, repo): its position and head, (0, 0) if never written.
    function getHead(address publisher, bytes32 repo_id) external view returns (uint64 pos, bytes32 head) {
        Head storage h = heads[publisher][repo_id];
        return (h.pos, h.head);
    }

    /// Repoint the AppRegistry this one names.
    function setAppRegistry(address registry) external onlyAdmin {
        appRegistry = registry;
    }

    /// Hand the admin role to another address. The admin is also who may upgrade this
    /// contract, so setting zero renounces both for good.
    function setAdmin(address new_admin) external onlyAdmin {
        emit AdminChanged(admin, new_admin);
        admin = new_admin;
    }

    /// Only the admin may point the proxy at a new implementation.
    function _authorizeUpgrade(address) internal override onlyAdmin {}

    modifier onlyAdmin() {
        if (msg.sender != admin) revert Unauthorized();
        _;
    }
}
