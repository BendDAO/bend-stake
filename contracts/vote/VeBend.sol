// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.0;

/***
 *@title VeBend
 *@notice Votes have a weight depending on time, so that users are
 *        committed to the future of (whatever they are voting for)
 *@dev Vote weight decays linearly over time. Lock time cannot be
 *     more than `MAXTIME` (4 years).
 */

// Voting escrow to have time-weighted votes
// Votes have a weight depending on time, so that users are committed
// to the future of (whatever they are voting for).
// The weight in this implementation is linear, and lock cannot be more than maxtime
// w ^
// 1 +        /
//   |      /
//   |    /
//   |  /
//   |/
// 0 +--------+------> time
//       maxtime (4 years?)

// Interface for checking whether address belongs to a whitelisted
// type of a smart wallet.
// When new types are added - the whole contract is changed
// The check() method is modifying to be able to use caching
// for individual wallet addresses

//libraries
import {ISmartWalletChecker} from "./interfaces/ISmartWalletChecker.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VeBend is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    struct Point {
        int256 bias;
        int256 slope; // - dweight / dt
        uint256 ts; //timestamp
        uint256 blk; // block
    }
    // We cannot really do block numbers per se b/c slope is per time, not per block
    // and per block could be fairly bad b/c Ethereum changes blocktimes.
    // What we can do is to extrapolate ***At functions

    struct LockedBalance {
        int256 amount;
        uint256 end;
    }

    uint256 private constant DEPOSIT_FOR_TYPE = 0;
    uint256 private constant CREATE_LOCK_TYPE = 1;
    uint256 private constant INCREASE_LOCK_AMOUNT = 2;
    uint256 private constant INCREASE_UNLOCK_TIME = 3;

    event Deposit(
        address indexed provider,
        uint256 value,
        uint256 indexed locktime,
        uint256 _type,
        uint256 ts
    );
    event Withdraw(address indexed provider, uint256 value, uint256 ts);

    event Supply(uint256 prevSupply, uint256 supply);

    uint256 public constant WEEK = 7 * 86400; // all future times are rounded by week
    uint256 public constant MAXTIME = 4 * 365 * 86400; // 4 years
    uint256 public constant MULTIPLIER = 10**18;

    address public token;
    uint256 public supply;

    mapping(address => LockedBalance) public locked;

    //everytime user deposit/withdraw/change_locktime, these values will be updated;
    uint256 public epoch;
    Point[] public supplyPointHistory; // epoch -> unsigned point.
    mapping(address => Point[]) public userPointHistory; // user -> Point[user_epoch]
    mapping(address => uint256) public userPointEpoch;
    mapping(uint256 => int256) public slopeChanges; // time -> signed slope change

    string public name;
    string public symbol;
    uint256 public decimals;

    // Checker for whitelisted (smart contract) wallets which are allowed to deposit
    // The goal is to prevent tokenizing the escrow
    address public smartWalletChecker;

    constructor(
        address _tokenAddr,
        string memory _name,
        string memory _symbol
    ) {
        token = _tokenAddr;
        supplyPointHistory[0].blk = block.number;
        supplyPointHistory[0].ts = block.timestamp;
        decimals = 18;
        name = _name;
        symbol = _symbol;
    }

    /***
     *@dev Check if the call is from a whitelisted smart contract, revert if not
     *@param _addr Address to be checked
     */
    function assertNotContract(address _addr) internal {
        if (_addr != tx.origin) {
            address checker = smartWalletChecker; //not going to be deployed at the moment of launch.
            if (checker != address(0)) {
                if (ISmartWalletChecker(checker).check(_addr)) {
                    return;
                }
            }
            revert("Smart contract depositors not allowed");
        }
    }

    /***
     *@dev Get the most recently recorded rate of voting power decrease for `_addr`
     *@param _addr Address of the user wallet
     *@return Value of the slope
     */
    function getLastUserSlope(address _addr) external view returns (int256) {
        uint256 uepoch = userPointEpoch[_addr];
        return userPointHistory[_addr][uepoch].slope;
    }

    /***
     *@dev Get the timestamp for checkpoint `_idx` for `_addr`
     *@param _addr User wallet address
     *@param _idx User epoch number
     *@return Epoch time of the checkpoint
     */
    function userPointHistoryTs(address _addr, uint256 _idx)
        external
        view
        returns (uint256)
    {
        return userPointHistory[_addr][_idx].ts;
    }

    /***
     *@dev Get timestamp when `_addr`'s lock finishes
     *@param _addr User wallet
     *@return Epoch time of the lock end
     */
    function lockedEnd(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    /***
     *@dev Record global and per-user data to checkpoint
     *@param _addr User's wallet address. No user checkpoint if 0x0
     *@param _oldLocked Pevious locked amount / end lock time for the user
     *@param _newLocked New locked amount / end lock time for the user
     */
    function _checkpoint(
        address _addr,
        LockedBalance memory _oldLocked,
        LockedBalance memory _newLocked
    ) internal {
        Point memory _userOldPoint;
        Point memory _userNewPoint;
        int256 _oldDslope = 0;
        int256 _newDslope = 0;
        uint256 _epoch = epoch;

        if (_addr != address(0)) {
            // Calculate slopes and biases
            // Kept at zero when they have to
            if (_oldLocked.end > block.timestamp && _oldLocked.amount > 0) {
                _userOldPoint.slope = _oldLocked.amount / int256(MAXTIME);
                _userOldPoint.bias =
                    _userOldPoint.slope *
                    int256(_oldLocked.end - block.timestamp);
            }
            if (_newLocked.end > block.timestamp && _newLocked.amount > 0) {
                _userNewPoint.slope = _newLocked.amount / int256(MAXTIME);
                _userNewPoint.bias =
                    _userNewPoint.slope *
                    int256(_newLocked.end - block.timestamp);
            }

            // Read values of scheduled changes in the slope
            // _oldLocked.end can be in the past and in the future
            // _newLocked.end can ONLY by in the FUTURE unless everything expired than zeros
            _oldDslope = slopeChanges[_oldLocked.end];
            if (_newLocked.end != 0) {
                if (_newLocked.end == _oldLocked.end) {
                    _newDslope = _oldDslope;
                } else {
                    _newDslope = slopeChanges[_newLocked.end];
                }
            }
        }
        Point memory _lastPoint = Point({
            bias: 0,
            slope: 0,
            ts: block.timestamp,
            blk: block.number
        });
        if (_epoch > 0) {
            _lastPoint = supplyPointHistory[_epoch];
        }
        uint256 _lastCheckPoint = _lastPoint.ts;
        // _initialLastPoint is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory _initialLastPoint = _lastPoint;
        uint256 _blockSlope = 0; // dblock/dt
        if (block.timestamp > _lastPoint.ts) {
            _blockSlope =
                (MULTIPLIER * (block.number - _lastPoint.blk)) /
                (block.timestamp - _lastPoint.ts);
        }
        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint256 _ti = (_lastCheckPoint / WEEK) * WEEK;
        for (uint256 i; i < 255; i++) {
            // Hopefully it won't happen that this won't get used in 5 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            _ti += WEEK;
            int256 d_slope = 0;
            if (_ti > block.timestamp) {
                // reach future time, reset to blok time
                _ti = block.timestamp;
            } else {
                d_slope = slopeChanges[_ti];
            }
            _lastPoint.bias =
                _lastPoint.bias -
                _lastPoint.slope *
                int256(_ti - _lastCheckPoint);
            _lastPoint.slope += d_slope;
            if (_lastPoint.bias < 0) {
                // This can happen
                _lastPoint.bias = 0;
            }
            if (_lastPoint.slope < 0) {
                // This cannot happen - just in case
                _lastPoint.slope = 0;
            }
            _lastCheckPoint = _ti;
            _lastPoint.ts = _ti;
            _lastPoint.blk =
                _initialLastPoint.blk +
                ((_blockSlope * (_ti - _initialLastPoint.ts)) / MULTIPLIER);
            _epoch += 1;
            if (_ti == block.timestamp) {
                // history filled over, break loop
                _lastPoint.blk = block.number;
                break;
            } else {
                supplyPointHistory[_epoch] = _lastPoint;
            }
        }
        epoch = _epoch;
        // Now supplyPointHistory is filled until t=now

        if (_addr != address(0)) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            _lastPoint.slope += _userNewPoint.slope - _userOldPoint.slope;
            _lastPoint.bias += _userNewPoint.bias - _userOldPoint.bias;
            if (_lastPoint.slope < 0) {
                _lastPoint.slope = 0;
            }
            if (_lastPoint.bias < 0) {
                _lastPoint.bias = 0;
            }
        }
        // Record the changed point into history
        supplyPointHistory[_epoch] = _lastPoint;

        if (_addr != address(0)) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [_newLocked.end]
            // and add old_user_slope to [_oldLocked.end]
            if (_oldLocked.end > block.timestamp) {
                // _oldDslope was <something> - _userOldPoint.slope, so we cancel that
                _oldDslope += _userOldPoint.slope;
                if (_newLocked.end == _oldLocked.end) {
                    _oldDslope -= _userNewPoint.slope; // It was a new deposit, not extension
                }
                slopeChanges[_oldLocked.end] = _oldDslope;
            }
            if (_newLocked.end > block.timestamp) {
                if (_newLocked.end > _oldLocked.end) {
                    _newDslope -= _userNewPoint.slope; // old slope disappeared at this point
                    slopeChanges[_newLocked.end] = _newDslope;
                }
                // else we recorded it already in _oldDslope
            }

            // Now handle user history
            uint256 _userEpoch = userPointEpoch[_addr] + 1;

            userPointEpoch[_addr] = _userEpoch;
            _userNewPoint.ts = block.timestamp;
            _userNewPoint.blk = block.number;
            userPointHistory[_addr][_userEpoch] = _userNewPoint;
        }
    }

    /***
     *@dev Deposit and lock tokens for a user
     *@param _addr User's wallet address
     *@param _value Amount to deposit
     *@param _unlockTime New time when to unlock the tokens, or 0 if unchanged
     *@param _lockedBalance Previous locked amount / timestamp
     */
    function _depositFor(
        address _addr,
        uint256 _value,
        uint256 _unlockTime,
        LockedBalance memory _lockedBalance,
        uint256 _type
    ) internal {
        LockedBalance memory _locked = LockedBalance(
            _lockedBalance.amount,
            _lockedBalance.end
        );
        LockedBalance memory _oldLocked = LockedBalance(
            _lockedBalance.amount,
            _lockedBalance.end
        );

        uint256 _supplyBefore = supply;
        supply = _supplyBefore + _value;
        //Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount = _locked.amount + int256(_value);
        if (_unlockTime != 0) {
            _locked.end = _unlockTime;
        }
        locked[_addr] = _locked;

        // Possibilities
        // Both _oldLocked.end could be current or expired (>/< block.timestamp)
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > block.timestamp (always)

        _checkpoint(_addr, _oldLocked, _locked);

        if (_value != 0) {
            IERC20(token).safeTransferFrom(_addr, address(this), _value);
        }

        emit Deposit(_addr, _value, _locked.end, _type, block.timestamp);
        emit Supply(_supplyBefore, _supplyBefore + _value);
    }

    /***
     *@notice Record total supply to checkpoint
     */
    function checkpointSupply() public {
        LockedBalance memory _a;
        LockedBalance memory _b;
        _checkpoint(address(0), _a, _b);
    }

    /***
     *@dev Deposit `_value` tokens for `_addr` and add to the lock
     *     Anyone (even a smart contract) can deposit for someone else, but
     *     cannot extend their locktime and deposit for a brand new user
     *@param _addr User's wallet address
     *@param _value Amount to add to user's lock
     */
    function depositFor(address _addr, uint256 _value) external nonReentrant {
        LockedBalance memory _locked = locked[_addr];

        require(_value > 0, "dev: need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(
            _locked.end > block.timestamp,
            "Cannot add to expired lock. Withdraw"
        );

        _depositFor(_addr, _value, 0, locked[_addr], DEPOSIT_FOR_TYPE);
    }

    /***
     *@dev Deposit `_value` tokens for `msg.sender` and lock until `_unlockTime`
     *@param _value Amount to deposit
     *@param _unlockTime Epoch time when tokens unlock, rounded down to whole weeks
     */
    function createLock(uint256 _value, uint256 _unlockTime)
        external
        nonReentrant
    {
        assertNotContract(msg.sender);
        _unlockTime = (_unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "dev: need non-zero value");
        require(_locked.amount == 0, "Withdraw old tokens first");
        require(
            _unlockTime > block.timestamp,
            "Can only lock until time in the future"
        );
        require(
            _unlockTime <= block.timestamp + MAXTIME,
            "Voting lock can be 4 years max"
        );

        _depositFor(msg.sender, _value, _unlockTime, _locked, CREATE_LOCK_TYPE);
    }

    /***
     *@dev Deposit `_value` additional tokens for `msg.sender`
     *        without modifying the unlock time
     *@param _value Amount of tokens to deposit and add to the lock
     */
    function increaseAmount(uint256 _value) external nonReentrant {
        assertNotContract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];

        assert(_value > 0);
        require(_locked.amount > 0, "No existing lock found");
        require(
            _locked.end > block.timestamp,
            "Cannot add to expired lock. Withdraw"
        );

        _depositFor(msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /***
     *@dev Extend the unlock time for `msg.sender` to `_unlockTime`
     *@param _unlockTime New epoch time for unlocking
     */
    function increaseUnlockTime(uint256 _unlockTime) external nonReentrant {
        assertNotContract(msg.sender); //@shun: need to convert to solidity
        LockedBalance memory _locked = locked[msg.sender];
        _unlockTime = (_unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks

        require(_locked.end > block.timestamp, "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(_unlockTime > _locked.end, "Can only increase lock duration");
        require(
            _unlockTime <= block.timestamp + MAXTIME,
            "Voting lock can be 4 years max"
        );

        _depositFor(msg.sender, 0, _unlockTime, _locked, INCREASE_UNLOCK_TIME);
    }

    /***
     *@dev Withdraw all tokens for `msg.sender`
     *@dev Only possible if the lock has expired
     */
    function withdraw() external nonReentrant {
        LockedBalance memory _locked = LockedBalance(
            locked[msg.sender].amount,
            locked[msg.sender].end
        );

        require(block.timestamp >= _locked.end, "The lock didn't expire");
        uint256 _value = uint256(_locked.amount);

        LockedBalance memory _oldLocked = LockedBalance(
            locked[msg.sender].amount,
            locked[msg.sender].end
        );

        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 _supplyBefore = supply;
        supply = _supplyBefore - _value;

        // _oldLocked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, _oldLocked, _locked);

        IERC20(token).safeTransfer(msg.sender, _value);

        emit Withdraw(msg.sender, _value, block.timestamp);
        emit Supply(_supplyBefore, _supplyBefore - _value);
    }

    // The following ERC20/minime-compatible methods are not real balanceOf and supply!
    // They measure the weights for the purpose of voting, so they don't represent
    // real coins.

    /***
     *@dev Binary search to estimate timestamp for block number
     *@param _block Block to find
     *@param _max_epoch Don't go beyond this epoch
     *@return Approximate timestamp for block
     */
    function findBlockEpoch(uint256 _block, uint256 _max_epoch)
        internal
        view
        returns (uint256)
    {
        // Binary search
        uint256 _min = 0;
        uint256 _max = _max_epoch;
        for (uint256 i; i <= 128; i++) {
            // Will be always enough for 128-bit numbers
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (supplyPointHistory[_mid].blk <= _block) {
                _min = _mid;
            } else {
                _max = _mid - 1;
            }
        }
        return _min;
    }

    /***
     *@notice Get the current voting power for `msg.sender`
     *@dev Adheres to the ERC20 `balanceOf` interface for Metamask & Snapshot compatibility
     *@param _addr User wallet address
     *@return User's present voting power
     */
    function balanceOf(address _addr) external view returns (uint256) {
        uint256 _t = block.timestamp;

        uint256 _epoch = userPointEpoch[_addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory _lastPoint = userPointHistory[_addr][_epoch];
            _lastPoint.bias -= _lastPoint.slope * int256(_t - _lastPoint.ts);
            if (_lastPoint.bias < 0) {
                _lastPoint.bias = 0;
            }
            return uint256(_lastPoint.bias);
        }
    }

    /***
     *@notice Get the current voting power for `msg.sender`
     *@dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
     *@param _addr User wallet address
     *@param _t Epoch time to return voting power at
     *@return User voting power
     *@dev return the present voting power if _t is 0
     */
    function balanceOf(address _addr, uint256 _t)
        external
        view
        returns (uint256)
    {
        if (_t == 0) {
            _t = block.timestamp;
        }

        uint256 _epoch = userPointEpoch[_addr];
        if (_epoch == 0) {
            return 0;
        } else {
            Point memory _lastPoint = userPointHistory[_addr][_epoch];
            _lastPoint.bias -= _lastPoint.slope * int256(_t - _lastPoint.ts);
            if (_lastPoint.bias < 0) {
                _lastPoint.bias = 0;
            }
            return uint256(_lastPoint.bias);
        }
    }

    //Struct to avoid "Stack Too Deep"
    struct Parameters {
        uint256 min;
        uint256 max;
        uint256 maxEpoch;
        uint256 dBlock;
        uint256 dt;
    }

    /***
     *@notice Measure voting power of `_addr` at block height `_block`
     *@dev Adheres to MiniMe `balanceOfAt` interface https//github.com/Giveth/minime
     *@param _addr User's wallet address
     *@param _block Block to calculate the voting power at
     *@return Voting power
     */
    function balanceOfAt(address _addr, uint256 _block)
        external
        view
        returns (uint256)
    {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        assert(_block <= block.number);

        Parameters memory _st;

        // Binary search
        _st.min = 0;
        _st.max = userPointEpoch[_addr];
        for (uint256 i; i <= 128; i++) {
            // Will be always enough for 128-bit numbers
            if (_st.min >= _st.max) {
                break;
            }
            uint256 _mid = (_st.min + _st.max + 1) / 2;
            if (userPointHistory[_addr][_mid].blk <= _block) {
                _st.min = _mid;
            } else {
                _st.max = _mid - 1;
            }
        }

        Point memory _upoint = userPointHistory[_addr][_st.min];

        _st.maxEpoch = epoch;
        uint256 _epoch = findBlockEpoch(_block, _st.maxEpoch);
        Point memory _point = supplyPointHistory[_epoch];
        _st.dBlock = 0;
        _st.dt = 0;
        if (_epoch < _st.maxEpoch) {
            Point memory _point_1 = supplyPointHistory[_epoch + 1];
            _st.dBlock = _point_1.blk - _point.blk;
            _st.dt = _point_1.ts - _point.ts;
        } else {
            _st.dBlock = block.number - _point.blk;
            _st.dt = block.timestamp - _point.ts;
        }
        uint256 block_time = _point.ts;
        if (_st.dBlock != 0) {
            block_time += (_st.dt * (_block - _point.blk)) / _st.dBlock;
        }

        _upoint.bias -= _upoint.slope * int256(block_time - _upoint.ts);
        if (_upoint.bias >= 0) {
            return uint256(_upoint.bias);
        } else {
            return 0;
        }
    }

    /***
     *@dev Calculate total voting power at some point in the past
     *@param point The point (bias/slope) to start search from
     *@param t Time to calculate the total voting power at
     *@return Total voting power at that time
     */
    function supplyAt(Point memory point, uint256 t)
        internal
        view
        returns (uint256)
    {
        Point memory _lastPoint = point;
        uint256 _ti = (_lastPoint.ts / WEEK) * WEEK;
        for (uint256 i; i < 255; i++) {
            _ti += WEEK;
            int256 d_slope = 0;

            if (_ti > t) {
                _ti = t;
            } else {
                d_slope = slopeChanges[_ti];
            }
            _lastPoint.bias -= _lastPoint.slope * int256(_ti - _lastPoint.ts);

            if (_ti == t) {
                break;
            }
            _lastPoint.slope += d_slope;
            _lastPoint.ts = _ti;
        }

        if (_lastPoint.bias < 0) {
            _lastPoint.bias = 0;
        }
        return uint256(_lastPoint.bias);
    }

    /***
     *@notice Calculate total voting power
     *@dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     *@return Total voting power
     */
    function totalSupply() external view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory _lastPoint = supplyPointHistory[_epoch];

        return supplyAt(_lastPoint, block.timestamp);
    }

    /***
     *@notice Calculate total voting power
     *@dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
     *@return Total voting power
     */
    function totalSupply(uint256 _t) external view returns (uint256) {
        if (_t == 0) {
            _t = block.timestamp;
        }

        uint256 _epoch = epoch;
        Point memory _lastPoint = supplyPointHistory[_epoch];

        return supplyAt(_lastPoint, _t);
    }

    /***
     *@notice Calculate total voting power at some point in the past
     *@param _block Block to calculate the total voting power at
     *@return Total voting power at `_block`
     */
    function totalSupplyAt(uint256 _block) external view returns (uint256) {
        assert(_block <= block.number);
        uint256 _epoch = epoch;
        uint256 _targetEpoch = findBlockEpoch(_block, _epoch);

        Point memory _point = supplyPointHistory[_targetEpoch];
        uint256 dt = 0;
        if (_targetEpoch < _epoch) {
            Point memory _pointNext = supplyPointHistory[_targetEpoch + 1];
            if (_point.blk != _pointNext.blk) {
                dt =
                    ((_block - _point.blk) * (_pointNext.ts - _point.ts)) /
                    (_pointNext.blk - _point.blk);
            }
        } else {
            if (_point.blk != block.number) {
                dt =
                    ((_block - _point.blk) * (block.timestamp - _point.ts)) /
                    (block.number - _point.blk);
            }
        }
        // Now dt contains info on how far are we beyond point

        return supplyAt(_point, _point.ts + dt);
    }

    function getUserPointEpoch(address _user) external view returns (uint256) {
        return userPointEpoch[_user];
    }

    /***
     *@notice Set an external contract to check for approved smart contract wallets
     *@param _addr Address of Smart contract checker
     */
    function commitSmartWalletChecker(address _addr) external onlyOwner {
        smartWalletChecker = _addr;
    }
}
