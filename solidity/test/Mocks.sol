// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AppRegistry} from "../src/AppRegistry.sol";
import {DataRegistry} from "../src/DataRegistry.sol";

/// A fee token that records what it was asked to move and can be told to refuse.
contract MockUSDC {
    enum Mode {
        Ok,
        Revert,
        ReturnFalse
    }

    Mode public mode;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;
    uint256 public calls;

    function setMode(Mode m) external {
        mode = m;
    }

    function _move(address from, address to, uint256 amount) private returns (bool) {
        require(mode != Mode.Revert, "usdc: refused");
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
        calls += 1;
        return mode == Mode.Ok;
    }

    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        return _move(from, to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        return _move(msg.sender, to, amount);
    }

    /// ERC-3009. The signature is not checked: these tests are about who gets paid.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32,
        uint8,
        bytes32,
        bytes32
    ) external {
        _move(from, to, value);
    }

    /// ERC-3009 receive: only `to` may redeem, and each nonce once.
    mapping(bytes32 => bool) public usedNonce;
    bytes32 public lastNonce;

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256,
        uint256,
        bytes32 nonce,
        uint8,
        bytes32,
        bytes32
    ) external {
        require(msg.sender == to, "usdc: caller must be the payee");
        require(!usedNonce[nonce], "usdc: authorization used");
        usedNonce[nonce] = true;
        lastNonce = nonce;
        _move(from, to, value);
    }
}

/// Semaphore partial impl. Records every call so a
/// test can assert which group and scope the registry actually used.
contract MockSemaphore {
    uint256 public nextGroup = 7;
    bool public failCreate;
    bool public failAdd;
    bool public failProof;

    uint256 public adds;
    uint256 public lastAddGroup;
    uint256 public lastAddCommitment;

    uint256 public proofs;
    uint256 public lastProofGroup;
    uint256 public lastProofScope;
    uint256 public lastProofNullifier;
    uint256 public lastProofMessage;

    struct SemaphoreProof {
        uint256 merkleTreeDepth;
        uint256 merkleTreeRoot;
        uint256 nullifier;
        uint256 message;
        uint256 scope;
        uint256[8] points;
    }

    function setFail(bool create, bool add, bool proof) external {
        failCreate = create;
        failAdd = add;
        failProof = proof;
    }

    function createGroup() external returns (uint256 id) {
        require(!failCreate, "semaphore: no group");
        id = nextGroup++;
    }

    function addMember(uint256 groupId, uint256 identityCommitment) external {
        require(!failAdd, "semaphore: no member");
        adds += 1;
        lastAddGroup = groupId;
        lastAddCommitment = identityCommitment;
    }

    function validateProof(uint256 groupId, SemaphoreProof calldata proof) external {
        require(!failProof, "semaphore: bad proof");
        proofs += 1;
        lastProofGroup = groupId;
        lastProofScope = proof.scope;
        lastProofNullifier = proof.nullifier;
        lastProofMessage = proof.message;
    }
}

/// A Semaphore whose createGroup returns 8 bytes instead of a uint256.
contract ShortSemaphore {
    fallback() external {
        assembly {
            return(0, 8)
        }
    }
}

/// An afterSettle hook that records what it was handed and can be told to fail.
contract MockHook {
    bool public fail;
    uint256 public calls;
    bytes32 public lastResource;
    uint256 public lastNullifier;
    uint256 public lastMessage;
    bytes public lastData;

    function setFail(bool f) external {
        fail = f;
    }

    function afterSettle(bytes32 resourceId, uint256 nullifierHash, uint256 message, bytes calldata data) external {
        require(!fail, "hook: no");
        calls += 1;
        lastResource = resourceId;
        lastNullifier = nullifierHash;
        lastMessage = message;
        lastData = data;
    }
}

/// The AppRegistry, as far as the DataRegistry can see it: one settable answer per
/// (app, publisher).
contract MockAppRegistry {
    mapping(bytes32 => mapping(address => bool)) public isRegisteredForApp;

    function setMember(bytes32 appId, address publisher, bool joined) external {
        isRegisteredForApp[appId][publisher] = joined;
    }
}

/// Reverts on every call, including the views the registries cross-call.
contract Reverter {
    fallback() external payable {
        revert("no");
    }
}

/// Deploys each registry the way `deploy.sh` does: an implementation, and the ERC-1967
/// proxy that initializes it. What comes back is the proxy, so every test runs against
/// proxy storage — including the reentrancy guard, which starts at zero there.
library Proxied {
    function appRegistry(address admin, address usdc, uint256 subscriptionFee, address dataRegistry_)
        internal
        returns (AppRegistry)
    {
        bytes memory init = abi.encodeCall(AppRegistry.initialize, (admin, usdc, subscriptionFee, dataRegistry_));
        return AppRegistry(address(new ERC1967Proxy(address(new AppRegistry()), init)));
    }

    function dataRegistry(address admin, uint256 registrationFee, address appRegistry_)
        internal
        returns (DataRegistry)
    {
        bytes memory init = abi.encodeCall(DataRegistry.initialize, (admin, registrationFee, appRegistry_));
        return DataRegistry(address(new ERC1967Proxy(address(new DataRegistry()), init)));
    }

}
