// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Rebasing token: every balance is scaled by a settable factor, so a holder's
///         balance changes with no transfer. The pool must account by what it
///         recorded at deposit, never by what the token says later.
contract MockRebasingERC20 is ERC20 {
    uint256 public factorBps = 10_000;

    constructor() ERC20("Rebase", "RBS") {}

    function mint(address to, uint256 amount) external {
        _mint(to, (amount * 10_000) / factorBps);
    }

    function setFactorBps(uint256 f) external {
        factorBps = f;
    }

    function balanceOf(address a) public view override returns (uint256) {
        return (super.balanceOf(a) * factorBps) / 10_000;
    }

    function transfer(address to, uint256 v) public override returns (bool) {
        return super.transfer(to, (v * 10_000) / factorBps);
    }

    function transferFrom(address f, address to, uint256 v) public override returns (bool) {
        return super.transferFrom(f, to, (v * 10_000) / factorBps);
    }
}

/// @notice ERC777-style token: once armed, the next transfer calls the target set by `arm`.
///         This is a reentrancy surface a plain ERC-20 does not have.
contract MockReentrantERC20 is ERC20 {
    address public target;
    bytes public payload;
    bool public armed;
    bool public fired;
    bytes public lastError;

    constructor() ERC20("Hook", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target_, bytes calldata payload_) external {
        target = target_;
        payload = payload_;
        armed = true;
        fired = false;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (armed && target != address(0)) {
            armed = false; // one shot, so the callback cannot recurse forever
            fired = true;
            (bool ok, bytes memory err) = target.call(payload);
            if (!ok) lastError = err;
        }
    }
}

/// @notice Reverts on a zero-value transfer, as some real tokens do, and on any transfer to or
///         from a blocked address, as compliance tokens do.
contract MockPickyERC20 is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("Picky", "PICK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function block_(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(value != 0, "no zero transfers");
        require(!blocked[to] && !blocked[from], "blocked");
        super._update(from, to, value);
    }
}

/// @notice Reports 36 decimals and returns no boolean from approve, transfer or transferFrom,
///         as USDT does. The pool has to handle both.
contract MockNoReturnERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint8 public constant decimals = 36;
    string public constant name = "NoReturn";
    string public constant symbol = "NRT";
    uint256 public totalSupply;

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
        totalSupply += a;
    }

    function approve(address s, uint256 a) external {
        allowance[msg.sender][s] = a;
    }

    /// @dev Returns no value, like USDT.
    function transfer(address to, uint256 a) external {
        balanceOf[msg.sender] -= a;
        balanceOf[to] += a;
    }

    function transferFrom(address f, address to, uint256 a) external {
        allowance[f][msg.sender] -= a;
        balanceOf[f] -= a;
        balanceOf[to] += a;
    }
}
