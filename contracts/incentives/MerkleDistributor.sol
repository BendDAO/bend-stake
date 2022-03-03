// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMerkleDistributor} from "./interfaces/IMerkleDistributor.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";

contract MerkleDistributor is
    IMerkleDistributor,
    Pausable,
    Ownable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;
    IERC20 public immutable override token;
    bool public isMerkleRootSet;
    bytes32 public override merkleRoot;
    uint256 public endTimestamp;
    mapping(bytes32 => mapping(address => bool)) public claimed;

    constructor(IERC20 _token) {
        token = _token;
    }

    function pauseAirdrop() external onlyOwner whenNotPaused {
        _pause();
    }

    function unpauseAirdrop() external onlyOwner whenPaused {
        _unpause();
    }

    /**
     * @notice Set merkle root for airdrop
     * @param _merkleRoot merkle root
     */
    function setMerkleRoot(bytes32 _merkleRoot) external onlyOwner {
        require(!isMerkleRootSet, "Owner: Merkle root already set");

        isMerkleRootSet = true;
        merkleRoot = _merkleRoot;

        emit MerkleRootSet(_merkleRoot);
    }

    /**
     * @notice Update end timestamp
     * @param _endTimestamp new endtimestamp
     */
    function setEndTimestamp(uint256 _endTimestamp) external onlyOwner {
        require(
            block.timestamp < _endTimestamp,
            "Owner: Can't set past timestamp"
        );
        endTimestamp = _endTimestamp;

        emit EndTimestampSet(_endTimestamp);
    }

    function _isClaimed(bytes32 _merkleRoot, address _account)
        internal
        view
        returns (bool)
    {
        bool _claimed = claimed[_merkleRoot][_account];
        return _claimed;
    }

    function isClaimed(address _account) public view override returns (bool) {
        require(isMerkleRootSet, "Airdrop: Merkle root not set");
        return _isClaimed(merkleRoot, _account);
    }

    function _setClaimed(bytes32 _merkleRoot, address _account) private {
        claimed[_merkleRoot][_account] = true;
    }

    function claim(
        address account,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) external override whenNotPaused nonReentrant {
        require(block.timestamp <= endTimestamp, "Airdrop: Too late to claim");
        require(
            !isClaimed(account),
            "MerkleDistributor: Drop already claimed."
        );

        // Verify the merkle proof.
        bytes32 node = keccak256(abi.encodePacked(account, amount));
        require(
            MerkleProof.verify(merkleProof, merkleRoot, node),
            "MerkleDistributor: Invalid proof."
        );

        // Mark it claimed and send the token.
        _setClaimed(merkleRoot, account);
        token.safeTransfer(account, amount);

        emit Claimed(merkleRoot, account, amount);
    }

    /**
     * @notice Transfer tokens back to owner
     */
    function withdrawTokenRewards() external onlyOwner {
        require(
            block.timestamp > (endTimestamp + 1 days),
            "Owner: Too early to remove rewards"
        );
        uint256 balanceToWithdraw = token.balanceOf(address(this));
        token.safeTransfer(msg.sender, balanceToWithdraw);

        emit TokensWithdrawn(balanceToWithdraw);
    }
}