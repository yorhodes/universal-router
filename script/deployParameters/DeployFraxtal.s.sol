// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployFraxtal is DeployUniversalRouter {
    function setUp() public virtual override {
        params = DeploymentParameters({
            weth9: 0xFc00000000000000000000000000000000000002,
            v2Factory: UNSUPPORTED_PROTOCOL,
            v3Factory: UNSUPPORTED_PROTOCOL,
            pairInitCodeHash: BYTES32_ZERO,
            poolInitCodeHash: BYTES32_ZERO,
            v4PoolManager: UNSUPPORTED_PROTOCOL,
            veloV2Factory: 0x31832f2a97Fd20664D76Cc421207669b55CE4BC0,
            veloCLFactory: address(0),
            veloV2InitCodeHash: 0x558be7ee0c63546b31d0773eee1d90451bd76a0167bb89653722a2bd677c002d,
            veloCLInitCodeHash: bytes32(0),
            veloCLFactory2: 0x04625B046C69577EfC40e6c0Bb83CDBAfab5a55F,
            veloCLInitCodeHash2: 0x7b216153c50849f664871825fa6f22b3356cdce2436e4f48734ae2a926a4c7e5,
            veloCLFactory3: 0x718E46d0962A66942E233760a8bd6038Ce54EdCD,
            veloCLInitCodeHash3: 0x5c321b71432b05a17f62ebb2aef808690c7902c12aa1c492ef3d5a3cc12a0c0b
        });

        outputFilename = 'fraxtal.json';
    }
}
