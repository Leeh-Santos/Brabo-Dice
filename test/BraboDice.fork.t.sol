// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {BraboDice} from "../src/BraboDice.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IVRFSubscriptionV2Plus} from
    "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol";

/// @notice Runs against a Base mainnet fork with the real $BRB token and VRF v2.5 coordinator.
///         Skipped unless BASE_RPC_URL is set:
///   BASE_RPC_URL=https://mainnet.base.org forge test --match-contract BraboDiceForkTest
contract BraboDiceForkTest is Test {
    address constant BRB = 0x07f6A4932e8be5Be7a0aC1bfCAB5EF6b95B0b1a2;
    address constant VRF_COORDINATOR = 0xd5D517aBE5cF79B7e95eC98dB0f0277788aFF634;
    bytes32 constant KEY_HASH = 0xdc2f87677b01473c763cb0aee938ed3341512f6057324a584e5944e786144d70;
    uint32 constant CALLBACK_GAS_LIMIT = 250_000;

    BraboDice dice;
    IERC20 brb = IERC20(BRB);
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint256 constant BET = 1_000 ether;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);

        uint256 subId = IVRFSubscriptionV2Plus(VRF_COORDINATOR).createSubscription();
        dice = new BraboDice(BRB, VRF_COORDINATOR, subId, KEY_HASH);
        IVRFSubscriptionV2Plus(VRF_COORDINATOR).addConsumer(subId, address(dice));

        deal(BRB, alice, 10 * BET);
        deal(BRB, bob, 10 * BET);
        vm.prank(alice);
        brb.approve(address(dice), type(uint256).max);
        vm.prank(bob);
        brb.approve(address(dice), type(uint256).max);
    }

    /// @dev Reads the requestId the real coordinator emitted in RandomWordsRequested.
    function _lastRequestId(Vm.Log[] memory logs) internal pure returns (uint256) {
        bytes32 sig = keccak256(
            "RandomWordsRequested(bytes32,uint256,uint256,uint256,uint16,uint32,uint32,bytes,address)"
        );
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == sig) {
                (uint256 requestId,,,,,,) =
                    abi.decode(logs[i - 1].data, (uint256, uint256, uint16, uint32, uint32, bytes, address));
                return requestId;
            }
        }
        revert("no VRF request");
    }

    /// @dev Simulates the coordinator's callback with exactly the gas the contract asks for.
    function _fulfill(uint256 requestId, uint256 word) internal {
        uint256[] memory words = new uint256[](1);
        words[0] = word;
        vm.prank(VRF_COORDINATOR);
        dice.rawFulfillRandomWords{gas: CALLBACK_GAS_LIMIT}(requestId, words);
    }

    function _play(uint256 creatorWord, uint256 challengerWord) internal returns (uint256 gameId) {
        vm.recordLogs();
        vm.prank(alice);
        gameId = dice.throwCoin(BET);
        _fulfill(_lastRequestId(vm.getRecordedLogs()), creatorWord);
        assertEq(uint8(dice.getGame(gameId).status), uint8(BraboDice.Status.Open));

        vm.recordLogs();
        vm.prank(bob);
        dice.acceptChallenge(gameId);
        _fulfill(_lastRequestId(vm.getRecordedLogs()), challengerWord);
        assertEq(uint8(dice.getGame(gameId).status), uint8(BraboDice.Status.Finished));
    }

    function test_Fork_RealTokenHasNoTransferFee() public {
        vm.prank(alice);
        dice.throwCoin(BET);
        assertEq(brb.balanceOf(address(dice)), BET);
    }

    function test_Fork_CreatorWinsOnMatch() public {
        _play(1, 1);
        assertEq(brb.balanceOf(alice), 11 * BET);
        assertEq(brb.balanceOf(bob), 9 * BET);
        assertEq(brb.balanceOf(address(dice)), 0);
    }

    function test_Fork_ChallengerWinsOnMismatch() public {
        _play(0, 1);
        assertEq(brb.balanceOf(alice), 9 * BET);
        assertEq(brb.balanceOf(bob), 11 * BET);
    }

    /// @dev Worst case for the callback: winner has never held BRB (cold storage slot).
    function test_Fork_CallbackFitsGasLimitForFreshWinner() public {
        address carol = makeAddr("carol");
        deal(BRB, carol, BET);
        vm.prank(carol);
        brb.approve(address(dice), BET);

        vm.recordLogs();
        vm.prank(carol);
        uint256 gameId = dice.throwCoin(BET); // carol now holds 0 BRB
        _fulfill(_lastRequestId(vm.getRecordedLogs()), 0);

        vm.recordLogs();
        vm.prank(bob);
        dice.acceptChallenge(gameId);
        _fulfill(_lastRequestId(vm.getRecordedLogs()), 0);

        assertEq(brb.balanceOf(carol), 2 * BET);
    }

    function test_Fork_RefundAfter24h() public {
        vm.recordLogs();
        vm.prank(alice);
        uint256 gameId = dice.throwCoin(BET);
        _fulfill(_lastRequestId(vm.getRecordedLogs()), 0);

        vm.warp(block.timestamp + 24 hours + 1);
        dice.refund(gameId);
        assertEq(brb.balanceOf(alice), 10 * BET);
    }
}
