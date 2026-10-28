// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {VRFConsumerBaseV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/// @title BraboDice — 1v1 $BRB coin flip
/// @notice Flow:
///   1. Creator calls throwCoin(amount): $BRB is locked and a VRF flip is requested.
///      When VRF answers, the game shows up in the lobby with the creator's side (0 = heads, 1 = tails).
///   2. A challenger calls acceptChallenge(gameId): locks the same amount and requests their own flip.
///   3. When the challenger's flip arrives: same side as the creator -> creator takes the pot,
///      different side -> challenger takes the pot.
///   If no challenger accepts within GAME_DURATION, the creator can reclaim the bet with refund().
///   If VRF never answers within VRF_TIMEOUT, refund() returns every locked deposit.
contract BraboDice is VRFConsumerBaseV2Plus {
    // ── Types ───────────────────────────────────────────────────────────────
    enum Status {
        None,
        AwaitingCreatorFlip, // creator deposited, waiting for VRF
        Open, // creator flip known, waiting for a challenger
        AwaitingChallengerFlip, // challenger deposited, waiting for VRF
        Finished,
        Refunded
    }

    struct Game {
        address creator;
        address challenger;
        address winner;
        uint256 amount; // per-player stake
        uint64 createdAt;
        uint64 acceptedAt;
        uint8 creatorSide; // 0 = heads, 1 = tails
        uint8 challengerSide;
        Status status;
    }

    // ── Constants / immutables ──────────────────────────────────────────────
    uint256 public constant GAME_DURATION = 24 hours;
    uint256 public constant VRF_TIMEOUT = 24 hours;

    uint32 private constant CALLBACK_GAS_LIMIT = 250_000;
    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    IERC20 public immutable i_brb;
    uint256 private immutable i_subscriptionId;
    bytes32 private immutable i_keyHash;

    // ── State ───────────────────────────────────────────────────────────────
    uint256 public s_nextGameId = 1;
    mapping(uint256 gameId => Game) private s_games;
    mapping(uint256 requestId => uint256 gameId) public s_requestToGame;

    /// @dev Lobby: ids of games in Status.Open (swap-and-pop set).
    uint256[] private s_openGames;
    mapping(uint256 gameId => uint256 indexPlusOne) private s_openGameIndex;

    /// @notice Payouts whose direct transfer failed inside the VRF callback; claim with withdraw().
    mapping(address player => uint256 amount) public s_pendingWithdrawals;

    // ── Events ──────────────────────────────────────────────────────────────
    event CoinThrown(uint256 indexed gameId, address indexed creator, uint256 amount, uint256 requestId);
    event GameOpened(uint256 indexed gameId, address indexed creator, uint256 amount, uint8 creatorSide);
    event ChallengeAccepted(uint256 indexed gameId, address indexed challenger, uint256 requestId);
    event GameFinished(
        uint256 indexed gameId, address indexed winner, uint8 creatorSide, uint8 challengerSide, uint256 payout
    );
    event GameRefunded(uint256 indexed gameId);
    event PayoutDeferred(address indexed player, uint256 amount);

    // ── Errors ──────────────────────────────────────────────────────────────
    error BraboDice__ZeroAmount();
    error BraboDice__TransferFailed();
    error BraboDice__FeeOnTransferNotSupported();
    error BraboDice__GameNotOpen(uint256 gameId);
    error BraboDice__GameExpired(uint256 gameId);
    error BraboDice__CannotChallengeOwnGame();
    error BraboDice__NotRefundable(uint256 gameId);
    error BraboDice__NothingToWithdraw();

    constructor(address brb, address vrfCoordinator, uint256 subscriptionId, bytes32 keyHash)
        VRFConsumerBaseV2Plus(vrfCoordinator)
    {
        i_brb = IERC20(brb);
        i_subscriptionId = subscriptionId;
        i_keyHash = keyHash;
    }

    // ── Player actions ──────────────────────────────────────────────────────

    /// @notice Lock `amount` $BRB (requires prior approve) and flip the creator's coin.
    function throwCoin(uint256 amount) external returns (uint256 gameId) {
        if (amount == 0) revert BraboDice__ZeroAmount();
        _pullExact(msg.sender, amount);

        gameId = s_nextGameId++;
        Game storage game = s_games[gameId];
        game.creator = msg.sender;
        game.amount = amount;
        game.createdAt = uint64(block.timestamp);
        game.status = Status.AwaitingCreatorFlip;

        uint256 requestId = _requestFlip();
        s_requestToGame[requestId] = gameId;
        emit CoinThrown(gameId, msg.sender, amount, requestId);
    }

    /// @notice Match the creator's stake (requires prior approve) and flip the challenger's coin.
    function acceptChallenge(uint256 gameId) external {
        Game storage game = s_games[gameId];
        if (game.status != Status.Open) revert BraboDice__GameNotOpen(gameId);
        if (block.timestamp > game.createdAt + GAME_DURATION) revert BraboDice__GameExpired(gameId);
        if (msg.sender == game.creator) revert BraboDice__CannotChallengeOwnGame();

        _pullExact(msg.sender, game.amount);

        game.challenger = msg.sender;
        game.acceptedAt = uint64(block.timestamp);
        game.status = Status.AwaitingChallengerFlip;
        _removeFromLobby(gameId);

        uint256 requestId = _requestFlip();
        s_requestToGame[requestId] = gameId;
        emit ChallengeAccepted(gameId, msg.sender, requestId);
    }

    /// @notice Return locked funds when a game can't complete. Callable by anyone; funds always go
    ///         back to the original depositors.
    ///   - Open and older than GAME_DURATION: creator gets the stake back.
    ///   - Stuck waiting on VRF for longer than VRF_TIMEOUT: each depositor gets their stake back.
    function refund(uint256 gameId) external {
        Game storage game = s_games[gameId];
        Status status = game.status;

        if (status == Status.Open) {
            if (block.timestamp <= game.createdAt + GAME_DURATION) revert BraboDice__NotRefundable(gameId);
            _removeFromLobby(gameId);
        } else if (status == Status.AwaitingCreatorFlip) {
            if (block.timestamp <= game.createdAt + VRF_TIMEOUT) revert BraboDice__NotRefundable(gameId);
        } else if (status == Status.AwaitingChallengerFlip) {
            if (block.timestamp <= game.acceptedAt + VRF_TIMEOUT) revert BraboDice__NotRefundable(gameId);
        } else {
            revert BraboDice__NotRefundable(gameId);
        }

        game.status = Status.Refunded;
        emit GameRefunded(gameId);

        _push(game.creator, game.amount);
        if (status == Status.AwaitingChallengerFlip) _push(game.challenger, game.amount);
    }

    /// @notice Claim payouts that could not be transferred during the VRF callback.
    function withdraw() external {
        uint256 amount = s_pendingWithdrawals[msg.sender];
        if (amount == 0) revert BraboDice__NothingToWithdraw();
        s_pendingWithdrawals[msg.sender] = 0;
        if (!i_brb.transfer(msg.sender, amount)) revert BraboDice__TransferFailed();
    }

    // ── VRF ─────────────────────────────────────────────────────────────────

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 gameId = s_requestToGame[requestId];
        delete s_requestToGame[requestId];
        Game storage game = s_games[gameId];
        uint8 side = uint8(randomWords[0] % 2);

        // Late answers for refunded games are ignored instead of reverting.
        if (game.status == Status.AwaitingCreatorFlip) {
            game.creatorSide = side;
            game.status = Status.Open;
            s_openGames.push(gameId);
            s_openGameIndex[gameId] = s_openGames.length;
            emit GameOpened(gameId, game.creator, game.amount, side);
        } else if (game.status == Status.AwaitingChallengerFlip) {
            game.challengerSide = side;
            game.status = Status.Finished;
            address winner = side == game.creatorSide ? game.creator : game.challenger;
            game.winner = winner;
            uint256 payout = game.amount * 2;
            emit GameFinished(gameId, winner, game.creatorSide, side, payout);
            _creditOrTransfer(winner, payout);
        }
    }

    // ── Views ───────────────────────────────────────────────────────────────

    function getGame(uint256 gameId) external view returns (Game memory) {
        return s_games[gameId];
    }

    /// @notice Ids of games waiting for a challenger (may include expired ones not yet refunded).
    function getOpenGames() external view returns (uint256[] memory) {
        return s_openGames;
    }

    function isExpired(uint256 gameId) external view returns (bool) {
        Game storage game = s_games[gameId];
        return game.status == Status.Open && block.timestamp > game.createdAt + GAME_DURATION;
    }

    // ── Internal ────────────────────────────────────────────────────────────

    function _requestFlip() private returns (uint256) {
        return s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: i_keyHash,
                subId: i_subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );
    }

    /// @dev Pulls `amount` and rejects tokens that deliver less than requested, so pots always add up.
    function _pullExact(address from, uint256 amount) private {
        uint256 before = i_brb.balanceOf(address(this));
        if (!i_brb.transferFrom(from, address(this), amount)) revert BraboDice__TransferFailed();
        if (i_brb.balanceOf(address(this)) - before != amount) revert BraboDice__FeeOnTransferNotSupported();
    }

    function _push(address to, uint256 amount) private {
        if (!i_brb.transfer(to, amount)) revert BraboDice__TransferFailed();
    }

    /// @dev Used inside the VRF callback, which must never revert: on failure the payout is parked.
    function _creditOrTransfer(address to, uint256 amount) private {
        (bool ok, bytes memory data) = address(i_brb).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) {
            s_pendingWithdrawals[to] += amount;
            emit PayoutDeferred(to, amount);
        }
    }

    function _removeFromLobby(uint256 gameId) private {
        uint256 indexPlusOne = s_openGameIndex[gameId];
        if (indexPlusOne == 0) return;
        uint256 lastId = s_openGames[s_openGames.length - 1];
        s_openGames[indexPlusOne - 1] = lastId;
        s_openGameIndex[lastId] = indexPlusOne;
        s_openGames.pop();
        delete s_openGameIndex[gameId];
    }
}
