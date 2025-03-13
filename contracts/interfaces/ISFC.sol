// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title Special Fee Contract for Sonic network
 * @notice The SFC maintains a list of validators and delegators and distributes rewards to them.
 * @custom:security-contact security@fantom.foundation
 */
interface ISFC {
    error StakeIsFullySlashed();

    function currentEpoch() external view returns (uint256);

    function getStake(address, uint256) external view returns (uint256);

    function getValidator(uint256) external view returns (uint256 status, uint256 receivedStake, address auth, uint256 createdEpoch, uint256 createdTime, uint256 deactivatedTime, uint256 deactivatedEpoch);

    function delegate(uint256 toValidatorID) external payable;

    function undelegate(uint256 toValidatorID, uint256 wrID, uint256 amount) external;

    function withdraw(uint256 toValidatorID, uint256 wrID) external;

    function pendingRewards(address delegator, uint256 toValidatorID) external view returns (uint256);

    function claimRewards(uint256 toValidatorID) external;

    function getSelfStake(uint256 validatorID) external view returns (uint256);

    function isSlashed(uint256 validatorID) external view returns (bool);

    function slashingRefundRatio(uint256 validatorID) external view returns (uint256);

    function constsAddress() external view returns (address);
}