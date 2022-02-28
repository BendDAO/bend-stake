// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

interface ILockup {
    struct LockParam {
        address beneficiary;
        uint256 percentage;
    }

    struct Locked {
        uint256 amount;
        uint256 slope;
    }

    event Lock(
        address indexed provider,
        address indexed beneficiary,
        uint256 value,
        uint256 ts
    );

    event BeneficiaryTransferred(
        address indexed previousBeneficiary,
        address indexed newBeneficiary,
        uint256 ts
    );

    event Withdrawn(address indexed beneficiary, uint256 value, uint256 ts);

    function lockEndTime() external view returns (uint256);

    function transferBeneficiary(
        address _oldBeneficiary,
        address _newBeneficiary
    ) external;

    function createLock(
        LockParam[] memory _beneficiaries,
        uint256 _totalAmount,
        uint256 _unlockStartTime,
        bool _lockForVoting
    ) external;

    function withdrawable(address _beneficiary) external view returns (uint256);

    function withdraw(address _beneficiary) external;

    function lockedAmount(address _beneficiary) external view returns (uint256);

    function claim() external;
}
