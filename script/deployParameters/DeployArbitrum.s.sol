// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DeployUniversalRouter} from '../DeployUniversalRouter.s.sol';

contract DeployArbitrum is DeployUniversalRouter {
    function setUp() public virtual override {
        params = DeploymentParameters({
            weth9: 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1,
            v2Factory: UNSUPPORTED_PROTOCOL,
            v3Factory: 0x1F98431c8aD98523631AE4a59f267346ea31F984,
            pairInitCodeHash: BYTES32_ZERO,
            poolInitCodeHash: 0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54,
            v4PoolManager: UNSUPPORTED_PROTOCOL,
            veloV2Factory: UNSUPPORTED_PROTOCOL,
            veloCLFactory: UNSUPPORTED_PROTOCOL,
            veloV2InitCodeHash: BYTES32_ZERO,
            veloCLInitCodeHash: BYTES32_ZERO,
            veloCLFactory2: UNSUPPORTED_PROTOCOL,
            veloCLInitCodeHash2: BYTES32_ZERO,
            veloCLFactory3: UNSUPPORTED_PROTOCOL,
            veloCLInitCodeHash3: BYTES32_ZERO
        });

        outputFilename = 'arbitrum.json';
    }
}
