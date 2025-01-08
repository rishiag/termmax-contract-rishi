// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ISwapCallback {
    function swapCallback(uint256 ftReserve) external;
}
