// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

contract BraboDice is VRFConsumerBaseV2Plus {
    // ── Chainlink VRF config ────────────────────────────────────────────────
    uint256 private immutable i_subscriptionId;
    bytes32 private immutable i_keyHash;
    uint32 private constant CALLBACK_GAS_LIMIT = 100_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    // ── State ───────────────────────────────────────────────────────────────
    mapping(uint256 requestId => address roller) public s_rollers;
    mapping(uint256 requestId => uint256 result) public s_results;

    // ── Events ──────────────────────────────────────────────────────────────
    event DiceRolled(uint256 indexed requestId, address indexed roller);
    event DiceResult(uint256 indexed requestId, address indexed roller, uint256 result);

    // ── Errors ──────────────────────────────────────────────────────────────
    error BraboDice__AlreadyRolled(uint256 requestId);

    constructor(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash
    ) VRFConsumerBaseV2Plus(vrfCoordinator) {
        i_subscriptionId = subscriptionId;
        i_keyHash = keyHash;
    }

    /// @notice Request a dice roll. Returns a requestId; the result arrives in fulfillRandomWords.
    function rollDice() external returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        s_rollers[requestId] = msg.sender;
        emit DiceRolled(requestId, msg.sender);
    }

    /// @notice Chainlink VRF callback — converts raw random into 1-6 and stores the result.
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 result = (randomWords[0] % 6) + 1; // 1-6
        s_results[requestId] = result;
        emit DiceResult(requestId, s_rollers[requestId], result);
    }
}
