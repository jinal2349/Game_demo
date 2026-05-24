// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

import "../chainlink-evm/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "../chainlink-evm/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
import "../chainlink-evm/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title FortunaVRFLottery
 * @notice Decentralized lottery using Chainlink VRF v2.5.
 *
 * Key Fix:
 * - Prize pool and jackpot reserve are tracked separately.
 * - Historical jackpot funds are never reused in future prize calculations.
 */
contract FortunaVRFLottery is
    VRFConsumerBaseV2Plus,
    Ownable,
    ReentrancyGuard
{
    enum LotteryState {
        Open,
        Calculating
    }

    // =============================================================
    // STATE VARIABLES
    // =============================================================

    /// @notice Players participating in current round.
    address[] public players;

    /// @notice Price per ticket.
    uint256 public immutable ticketPrice;

    /// @notice Current round number.
    uint256 public round;

    /// @notice Timestamp when current round ends.
    uint256 public roundEndTime;

    /// @notice Duration of each round.
    uint256 public immutable roundDuration;

    /// @notice Current state of lottery.
    LotteryState public lotteryState;

    /// @notice Most recent winner.
    address public recentWinner;

    /// @notice Current round ticket pool only.
    uint256 public currentRoundPool;

    /// @notice Accumulated house reserve.
    uint256 public jackpotReserve;

    /// @notice Winner percentage.
    uint256 public constant WINNER_PERCENT = 80;

    /// @notice Jackpot percentage.
    uint256 public constant JACKPOT_PERCENT = 20;

    // =============================================================
    // CHAINLINK VRF CONFIG
    // =============================================================

    IVRFCoordinatorV2Plus public immutable coordinator;

    uint256 public immutable subscriptionId;
    bytes32 public immutable keyHash;

    uint32 public callbackGasLimit = 200000;
    uint16 public requestConfirmations = 3;
    uint32 public numWords = 1;

    uint256 public lastRequestId;

    // =============================================================
    // EVENTS
    // =============================================================

    event NewRound(uint256 indexed round, uint256 endTime);

    event PlayerEntered(
        address indexed player,
        uint256 indexed round,
        uint256 amount
    );

    event WinnerPicked(
        address indexed winner,
        uint256 indexed round,
        uint256 prize,
        uint256 jackpotContribution
    );

    event RoundSkipped(uint256 indexed round);

    event JackpotWithdrawn(address indexed to, uint256 amount);

    // =============================================================
    // CONSTRUCTOR
    // =============================================================

    constructor(
        address vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint256 _ticketPrice,
        uint256 _roundDuration
    ) VRFConsumerBaseV2Plus(vrfCoordinator) Ownable(msg.sender) {
        require(vrfCoordinator != address(0), "Invalid coordinator");
        require(_ticketPrice > 0, "Invalid ticket price");
        require(_roundDuration > 0, "Invalid duration");

        coordinator = IVRFCoordinatorV2Plus(vrfCoordinator);

        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
        ticketPrice = _ticketPrice;
        roundDuration = _roundDuration;

        round = 1;
        lotteryState = LotteryState.Open;
        roundEndTime = block.timestamp + roundDuration;

        emit NewRound(round, roundEndTime);
    }

    // =============================================================
    // USER FUNCTIONS
    // =============================================================

    /**
     * @notice Enter current lottery round.
     */
    function enter() external payable nonReentrant {
        require(lotteryState == LotteryState.Open, "Lottery not open");
        require(block.timestamp < roundEndTime, "Round ended");
        require(msg.value == ticketPrice, "Incorrect ticket price");

        players.push(msg.sender);

        // IMPORTANT:
        // Only active round funds are added here.
        currentRoundPool += msg.value;

        emit PlayerEntered(msg.sender, round, msg.value);
    }

    // =============================================================
    // CHAINLINK AUTOMATION
    // =============================================================

    function checkUpkeep(
        bytes calldata
    )
        external
        view
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (
            lotteryState == LotteryState.Open &&
            block.timestamp >= roundEndTime &&
            players.length > 0
        );

        performData = "";
    }

    function performUpkeep(bytes calldata) external {
        require(lotteryState == LotteryState.Open, "Already calculating");
        require(block.timestamp >= roundEndTime, "Round not ended");

        // Skip empty rounds.
        if (players.length == 0) {
            emit RoundSkipped(round);
            _startNewRound();
            return;
        }

        lotteryState = LotteryState.Calculating;

        VRFV2PlusClient.RandomWordsRequest memory req = VRFV2PlusClient
            .RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: requestConfirmations,
                callbackGasLimit: callbackGasLimit,
                numWords: numWords,
                extraArgs: ""
            });

        lastRequestId = coordinator.requestRandomWords(req);
    }

    // =============================================================
    // VRF CALLBACK
    // =============================================================

    function fulfillRandomWords(
        uint256,
        uint256[] calldata randomWords
    ) internal override nonReentrant {
        require(players.length > 0, "No players");
        require(currentRoundPool > 0, "Empty pool");

        uint256 winnerIndex = randomWords[0] % players.length;
        address winner = players[winnerIndex];

        recentWinner = winner;

        // =========================================================
        // IMPORTANT FIX
        // =========================================================
        // Prize calculation uses ONLY currentRoundPool.
        // jackpotReserve is completely isolated.
        // =========================================================

        uint256 prize = (currentRoundPool * WINNER_PERCENT) / 100;
        uint256 jackpotAmount = currentRoundPool - prize;

        jackpotReserve += jackpotAmount;

        // Reset round pool BEFORE external transfer.
        currentRoundPool = 0;

        (bool success, ) = payable(winner).call{value: prize}("");
        require(success, "Prize transfer failed");

        emit WinnerPicked(winner, round, prize, jackpotAmount);

        _startNewRound();
    }

    // =============================================================
    // OWNER FUNCTIONS
    // =============================================================

    /**
     * @notice Withdraw accumulated jackpot reserve.
     */
    function withdrawJackpot(
        address payable to
    ) external onlyOwner nonReentrant {
        require(to != address(0), "Invalid address");
        require(jackpotReserve > 0, "No jackpot available");

        uint256 amount = jackpotReserve;

        jackpotReserve = 0;

        (bool success, ) = to.call{value: amount}("");
        require(success, "Withdrawal failed");

        emit JackpotWithdrawn(to, amount);
    }

    /**
     * @notice Update callback gas limit.
     */
    function setCallbackGasLimit(uint32 _gasLimit) external onlyOwner {
        callbackGasLimit = _gasLimit;
    }

    // =============================================================
    // INTERNAL FUNCTIONS
    // =============================================================

    function _startNewRound() internal {
        delete players;

        round += 1;
        roundEndTime = block.timestamp + roundDuration;

        lotteryState = LotteryState.Open;

        emit NewRound(round, roundEndTime);
    }

    // =============================================================
    // VIEW FUNCTIONS
    // =============================================================

    function getPlayers() external view returns (address[] memory) {
        return players;
    }

    function getCurrentPrizePool() external view returns (uint256) {
        return currentRoundPool;
    }

    function getTotalContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    // =============================================================
    // RECEIVE
    // =============================================================

    receive() external payable {
        jackpotReserve += msg.value;
    }
}
