// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";

/// The AppRegistry's one write from here: accept a head an update carries.
interface IAppRegistry {
    function acceptFromUpdate(
        bytes32 app_id,
        address publisher,
        bytes32 repo_id,
        string calldata repo,
        uint64 pos,
        bytes32 head
    ) external;
}

/// DataRegistry
///
/// The heads of every repo, and their update log (WHITEPAPER_1 §3.2, H and U).
///
/// A repo is `(publisher, repo)`: one publisher's data under a name it chooses. It
/// belongs to no app. Any address may update its own repos, with a compare-and-swap on
/// the head, and an update by itself changes what no app presents. Each update may
/// carry acceptances into apps (`apps`), which the AppRegistry applies after it; a
/// refused acceptance never undoes the update.
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
    /// Too little gas left to give a carried acceptance its budget.
    error InsufficientGas();

    /// Gas each carried acceptance gets. A refused acceptance never undoes the
    /// update, so without a fixed budget an update sent with too little gas would
    /// land with its acceptances silently out of gas — and gas estimation finds
    /// exactly that limit.
    uint256 public constant ACCEPT_GAS = 100_000;

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
    /// The AppRegistry: where carried acceptances go
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

    /// Move the sender's `repo` from `parent` to `head`, then try to accept the new head
    /// into each of `apps`. Reverts `StaleStateRoot` unless `parent` is the head.
    function update(string calldata repo, bytes32 parent, bytes32 head, bytes32[] calldata apps) external {
        if (head == bytes32(0)) revert ZeroHead();
        bytes32 repo_id = keccak256(bytes(repo));
        Head storage h = heads[msg.sender][repo_id];
        if (h.head != parent) revert StaleStateRoot();
        uint64 pos = h.pos + 1;
        h.pos = pos;
        h.head = head;
        emit Updated(msg.sender, repo_id, repo, pos, parent, head);

        for (uint256 i = 0; i < apps.length; i++) {
            // A call gets at most 63/64 of what is left (EIP-150).
            if (gasleft() < (ACCEPT_GAS * 64) / 63 + 10_000) revert InsufficientGas();
            try IAppRegistry(appRegistry).acceptFromUpdate{gas: ACCEPT_GAS}(
                apps[i], msg.sender, repo_id, repo, pos, head
            ) {}
                catch {}
        }
    }

    /// H(publisher, repo): its position and head, (0, 0) if never written.
    function getHead(address publisher, bytes32 repo_id) external view returns (uint64 pos, bytes32 head) {
        Head storage h = heads[publisher][repo_id];
        return (h.pos, h.head);
    }

    /// Repoint where carried acceptances go.
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
