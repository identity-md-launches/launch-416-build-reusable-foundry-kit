// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HookTestBase} from "./utils/HookTestBase.sol";
import {HookMiner} from "../src/HookMiner.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract MinerHarness {
    function find(address deployer, uint160 flags, bytes memory code, bytes memory args)
        external
        view
        returns (address, bytes32)
    {
        return HookMiner.find(deployer, flags, code, args);
    }
}

contract MinerTarget {
    uint256 public immutable value;

    constructor(uint256 value_) {
        value = value_;
    }
}

contract HookMinerTest is HookTestBase {
    MinerHarness internal miner;
    bytes internal code;
    bytes internal args;

    function setUp() public override {
        super.setUp();
        miner = new MinerHarness();
        code = type(MinerTarget).creationCode;
        args = abi.encode(uint256(123));
    }

    function testSeveralFlagSetsAndFirstSalt() public view {
        uint160[5] memory flags = [
            uint160(0),
            Hooks.BEFORE_INITIALIZE_FLAG,
            Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG,
            Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG,
            Hooks.ALL_HOOK_MASK
        ];
        bytes32 initHash = keccak256(bytes.concat(code, args));
        for (uint256 f; f < flags.length; ++f) {
            (address found, bytes32 salt) = miner.find(address(this), flags[f], code, args);
            assertLt(uint256(salt), 160_444);
            assertEq(found, _candidate(address(this), salt, initHash));
            assertEq(uint160(found) & Hooks.ALL_HOOK_MASK, flags[f]);
            assertEq(found.code.length, 0);
            for (uint256 i; i < uint256(salt); ++i) {
                assertNotEq(uint160(_candidate(address(this), bytes32(i), initHash)) & Hooks.ALL_HOOK_MASK, flags[f]);
            }
        }
    }

    function testDeploysFullInitCodeAndSkipsOccupiedAddress() public {
        uint160 flags = Hooks.AFTER_SWAP_FLAG;
        (address first, bytes32 firstSalt) = miner.find(address(this), flags, code, args);
        assertEq(address(deployHook(code, args, flags)), first);
        assertEq(MinerTarget(first).value(), 123);

        (address second, bytes32 secondSalt) = miner.find(address(this), flags, code, args);
        assertGt(uint256(secondSalt), uint256(firstSalt));
        assertNotEq(first, second);
        assertEq(address(deployHook(code, args, flags)), second);
        assertEq(MinerTarget(second).value(), 123);
    }

    function testRejectsOutOfRangeFlags() public {
        vm.expectRevert(HookMiner.FlagsOutOfRange.selector);
        miner.find(address(this), 1 << 14, code, args);
        vm.expectRevert(HookMiner.FlagsOutOfRange.selector);
        miner.find(address(this), (1 << 159) | Hooks.AFTER_SWAP_FLAG, code, args);
    }

    function testLastSaltIsIncludedAndExhaustionReverts() public {
        bytes32 initHash = keccak256(bytes.concat(code, args));
        address last = _candidate(address(this), bytes32(uint256(160_443)), initHash);
        uint160 flags = uint160(last) & Hooks.ALL_HOOK_MASK;
        for (uint256 i; i < 160_443; ++i) {
            address candidate = _candidate(address(this), bytes32(i), initHash);
            if (uint160(candidate) & Hooks.ALL_HOOK_MASK == flags) vm.etch(candidate, hex"00");
        }
        (address found, bytes32 salt) = miner.find(address(this), flags, code, args);
        assertEq(found, last);
        assertEq(uint256(salt), 160_443);
        vm.etch(last, hex"00");
        vm.expectRevert(HookMiner.HookMinerNotFound.selector);
        miner.find(address(this), flags, code, args);
    }

    function testSaltZeroIsIncluded() public view {
        bytes32 initHash = keccak256(bytes.concat(code, args));
        address expected = _candidate(address(0x1234), bytes32(0), initHash);
        (address found, bytes32 salt) = miner.find(address(0x1234), uint160(expected) & Hooks.ALL_HOOK_MASK, code, args);
        assertEq(found, expected);
        assertEq(salt, bytes32(0));
    }

    function _candidate(address deployer, bytes32 salt, bytes32 initHash) private pure returns (address result) {
        uint256 free;
        assembly ("memory-safe") {
            free := mload(0x40)
        }
        result = address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, salt, initHash)))));
        // The temporary encoding cannot escape; avoid growing memory across 160,444 oracle calls.
        assembly ("memory-safe") {
            mstore(0x40, free)
        }
    }
}
