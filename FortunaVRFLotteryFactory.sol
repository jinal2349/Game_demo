// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "./FortunaVRFLottery.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Fortuna VRF Lottery Factory
 * @notice Factory contract to deploy and track multiple FortunaVRFLottery instances.
 * Only the owner can create new lotteries.
 */
contract FortunaVRFLotteryFactory is Ownable {
    /// @notice List of all deployed FortunaVRFLottery contract addresses.
    address[] public allLotteries;

    /// @notice Emitted when a new FortunaVRFLottery is created.
    event LotteryCreated(
        address indexed lottery,
        uint256 indexed round,
        uint256 ticketPrice,
        uint256 roundDuration
    );

    /**
    * @notice Initializes the factory and sets the owner.
    */
    constructor() Ownable(msg.sender) {}

    /**
    * @notice Creates a new FortunaVRFLottery contract.
    * @param vrfCoordinator Address of the Chainlink VRF Coordinator.
    * @param subscriptionId Chainlink VRF subscription ID.
    * @param keyHash Chainlink VRF key hash.
    * @param ticketPrice Price of one ticket in wei.
    * @param roundDuration Duration of each round in seconds.
    * @return Address of the newly deployed FortunaVRFLottery contract.
    */
    function createLottery(
        address vrfCoordinator,
        uint256 subscriptionId,
        bytes32 keyHash,
        uint256 ticketPrice,
        uint256 roundDuration
    ) external onlyOwner returns (address) {
        FortunaVRFLottery lottery = new FortunaVRFLottery(
            vrfCoordinator,
            subscriptionId,
            keyHash,
            ticketPrice,
            roundDuration
        );

        allLotteries.push(address(lottery));

        emit LotteryCreated(
            address(lottery),
            lottery.round(),
            ticketPrice,
            roundDuration
        );

        return address(lottery);
    }

    /**
    * @notice Returns the list of all deployed FortunaVRFLottery contracts.
    */
    function getAllLotteries() external view returns (address[] memory) {
        return allLotteries;
    }

    /**
    * @notice Returns the number of deployed FortunaVRFLottery contracts.
    */
    function getLotteriesCount() external view returns (uint256) {
        return allLotteries.length;
    }
}
