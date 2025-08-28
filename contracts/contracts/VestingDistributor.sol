// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract VestingDistributor is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Policy {
        uint256 totalAllocation;
        uint256 lockMonths;
        uint256 vestingMonths;
        uint256 claimed;
    }

    IERC20 public immutable token;
    uint256 public tgeTimestamp;
    uint256 public totalAllocated;

    mapping(address => Policy[]) private _policies;
    address[] private _users;

    event PolicyAdded(address indexed user, uint256 allocation, uint256 lockMonths, uint256 vestingMonths);
    event UserPoliciesRemoved(address indexed user, uint256 removedPolicies, uint256 removedAllocationSum);
    event TGESet(uint256 tgeTimestamp);
    event Funded(address indexed from, uint256 amount);
    event Defunded(address indexed to, uint256 amount);
    event Distributed(address indexed user, uint256 amount);
    event DistributedAll(uint256 totalUsers, uint256 totalPaid);

    constructor(IERC20 _token, address _owner) Ownable(_owner) {
        token = _token;
    }

    function addPolicy(
        address user,
        uint256 allocation,
        uint256 lockMonths,
        uint256 vestingMonths
    ) external onlyOwner {
        require(tgeTimestamp == 0, "TGE set");
        require(user != address(0), "zero user");
        require(allocation > 0, "allocation=0");

        if (_policies[user].length == 0) {
            _users.push(user);
        }

        _policies[user].push(Policy({
            totalAllocation: allocation,
            lockMonths: lockMonths,
            vestingMonths: vestingMonths,
            claimed: 0
        }));

        totalAllocated += allocation;
        emit PolicyAdded(user, allocation, lockMonths, vestingMonths);
    }

    function removeAllPoliciesOf(address user) external onlyOwner {
        require(tgeTimestamp == 0, "TGE set");
        Policy[] storage arr = _policies[user];
        require(arr.length > 0, "no policies");

        uint256 sum;
        for (uint256 i = 0; i < arr.length; i++) {
            sum += arr[i].totalAllocation;
        }
        totalAllocated -= sum;

        delete _policies[user];

        uint256 len = _users.length;
        for (uint256 i = 0; i < len; i++) {
            if (_users[i] == user) {
                if (i != len - 1) _users[i] = _users[len - 1];
                _users.pop();
                break;
            }
        }

        emit UserPoliciesRemoved(user, arr.length, sum);
    }

    function setTGE(uint256 _tgeTimestamp) external onlyOwner {
        require(tgeTimestamp == 0, "already");
        require(_tgeTimestamp >= block.timestamp, "past");
        require(token.balanceOf(address(this)) == totalAllocated, "deposit != allocated");

        tgeTimestamp = _tgeTimestamp;
        emit TGESet(_tgeTimestamp);
    }

    function fund(uint256 amount) external onlyOwner {
        require(tgeTimestamp == 0, "TGE set");
        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    function defund(uint256 amount) external onlyOwner {
        require(tgeTimestamp == 0, "TGE set");
        token.safeTransfer(owner(), amount);
        emit Defunded(owner(), amount);
    }


    function distribute() external onlyOwner nonReentrant {
        require(tgeTimestamp > 0 && block.timestamp >= tgeTimestamp, "TGE not started");

        uint256 totalPaid;
        for (uint256 i = 0; i < _users.length; i++) {
            address user = _users[i];
            uint256 amt = _claimableUser(user);
            if (amt > 0) {
                _markClaimed(user, amt);
                token.safeTransfer(user, amt);
                totalPaid += amt;
                emit Distributed(user, amt);
            }
        }

        emit DistributedAll(_users.length, totalPaid);
    }

    function users() external view returns (address[] memory) {
        return _users;
    }

    function policyCountOf(address user) external view returns (uint256) {
        return _policies[user].length;
    }

    function getPolicy(address user, uint256 index) external view returns (
        uint256 allocation, uint256 lockMonths, uint256 vestingMonths, uint256 claimed
    ) {
        Policy memory p = _policies[user][index];
        return (p.totalAllocation, p.lockMonths, p.vestingMonths, p.claimed);
    }

    function claimable(address user) external view returns (uint256) {
        return _claimableUser(user);
    }

    function _claimableUser(address user) internal view returns (uint256) {
        if (tgeTimestamp == 0 || block.timestamp < tgeTimestamp) return 0;
        Policy[] memory arr = _policies[user];
        if (arr.length == 0) return 0;

        uint256 mp = (block.timestamp - tgeTimestamp) / 30 days;
        uint256 sum;

        for (uint256 i = 0; i < arr.length; i++) {
            Policy memory p = arr[i];
            if (mp < p.lockMonths) continue;

            uint256 unlocked;
            if (p.vestingMonths == 0) {
                unlocked = p.totalAllocation;
            } else {
                uint256 vestedMonths = mp - p.lockMonths;
                if (vestedMonths > p.vestingMonths) vestedMonths = p.vestingMonths;
                unlocked = (p.totalAllocation * vestedMonths) / p.vestingMonths;
            }

            if (unlocked > p.claimed) {
                sum += (unlocked - p.claimed);
            }
        }
        return sum;
    }

    function _markClaimed(address user, uint256 amount) internal {
        Policy[] storage arr = _policies[user];
        uint256 remaining = amount;
        uint256 mp = (block.timestamp - tgeTimestamp) / 30 days;

        for (uint256 i = 0; i < arr.length && remaining > 0; i++) {
            Policy storage p = arr[i];
            if (mp < p.lockMonths) continue;

            uint256 unlocked;
            if (p.vestingMonths == 0) {
                unlocked = p.totalAllocation;
            } else {
                uint256 vestedMonths = mp - p.lockMonths;
                if (vestedMonths > p.vestingMonths) vestedMonths = p.vestingMonths;
                unlocked = (p.totalAllocation * vestedMonths) / p.vestingMonths;
            }

            if (unlocked > p.claimed) {
                uint256 canClaim = unlocked - p.claimed;
                uint256 take = (canClaim > remaining) ? remaining : canClaim;
                p.claimed += take;
                remaining -= take;
            }
        }
    }
}
