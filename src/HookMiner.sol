// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "v4-core/src/libraries/Hooks.sol";

/// @notice Bounded CREATE2 search for an exact v4 hook permission mask.
library HookMiner {
    uint256 internal constant MAX_LOOP = 160_444;

    error HookMinerNotFound();
    error FlagsOutOfRange();

    /// @dev The deployer must be the contract executing CREATE2. An empty code check
    /// does not guarantee deployment (for example, an account may have a nonzero nonce).
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        if (flags & ~Hooks.ALL_HOOK_MASK != 0) revert FlagsOutOfRange();

        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        bytes memory preimage = abi.encodePacked(bytes1(0xff), deployer, bytes32(0), initCodeHash);
        for (uint256 i; i < MAX_LOOP; ++i) {
            bytes32 digest;
            // Reuse the 85-byte buffer: 0xff (1), deployer (20), salt (32), hash (32).
            assembly ("memory-safe") {
                mstore(add(preimage, 0x35), i)
                digest := keccak256(add(preimage, 0x20), 85)
            }
            hookAddress = address(uint160(uint256(digest)));
            if (uint160(hookAddress) & Hooks.ALL_HOOK_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, bytes32(i));
            }
        }
        revert HookMinerNotFound();
    }
}
