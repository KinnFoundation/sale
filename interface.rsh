"reach 0.1";
"use strict";

// -----------------------------------------------
// Name: KINN Token Sale Buy
// Version: 0.4.0 - buy api initial
// Requires Reach v0.1.11-rc7 (27cb9643) or later
// ----------------------------------------------

import {
  State,
  Params,
  view,
  baseState,
  baseEvents
} from "@KinnFoundation/base#base-v0.1.11r16:interface.rsh";

// CONSTANTS

const SERIAL_VER = 0;

// FUN

const fBuy = Fun(
  [
    Tuple(Contract, Contract),
    Tuple(Token),
    Tuple(Address),
    Contract,
    Address,
    UInt,
    UInt,
  ],
  Null
);
const rBuy = Fun([Address, UInt, UInt], Null);

const fBuyRemote = Fun(
  [
    Tuple(Contract, Contract),
    Tuple(Token),
    Tuple(Address),
    Contract,
    Address,
    UInt,
    UInt,
  ],
  Null
);
const rBuyRemote = Fun([Address, UInt, UInt], Null);

const fBuyRemoteToken = Fun(
  [
    Tuple(Contract, Contract),
    Tuple(Token),
    Tuple(Address),
    Contract,
    Address,
    UInt,
    UInt,
  ],
  Null
);
const rBuyRemoteToken = Fun([Address, UInt, UInt], Null);

const fSafeBuyRemoteToken = Fun(
  [
    Tuple(Contract, Contract),
    Tuple(Token),
    Tuple(Address),
    Contract,
    Address,
    UInt,
    UInt,
  ],
  Null
);
const rSafeBuyRemoteToken = Fun([Address, UInt, UInt], Null);

const fClose = Fun([], Null);

// API

export const api = {
  buy: fBuy, // remote
  buyRemote: fBuyRemote, // remote
  buyRemoteToken: fBuyRemoteToken, // remote
  safeBuyRemoteToken: fSafeBuyRemoteToken, // remote
  close: fClose, // manager only
};

// CONTRACT

export const Event = () => [Events({ ...baseEvents })];
export const Participants = () => [
  Participant("Manager", {
    getParams: Fun([], Params),
  }),
];
export const Views = () => [View(view(State))];
export const Api = () => [API(api)];
export const App = (map) => {
  const [{ amt, ttl, tok0: pToken }, [addr, _], [Manager], [v], [a], [e]] = map;
  Manager.publish()
    .pay([amt + SERIAL_VER])
    .timeout(relativeTime(ttl), () => {
      Anybody.publish();
      commit();
      exit();
    });
  transfer([amt + SERIAL_VER]).to(addr);
  e.appLaunch();

  const initialState = {
    ...baseState(Manager),
  };

  const [s] = parallelReduce([initialState])
    .define(() => {
      v.state.set(State.fromObject(s));
    })
    .invariant(balance() == 0, "balance accurate")
    .invariant(balance(pToken) == 0, "payment token balance accurate")
    .while(!s.closed)
    .paySpec([pToken])
    // api: buy
    //  - buy token (ALGO)
    .api_(a.buy, (ctcs, toks, addrs, ctc, /***/ recv, inTok, outCap) => {
      return [
        [inTok, [0, pToken]],
        (k) => {
          k(null);
          const r = remote(ctc, { buy: rBuy });
          r.buy
            .ALGO({ apps: ctcs, fees: 6, assets: toks, accounts: addrs })
            .pay(inTok)(recv, inTok, outCap);
          return [s];
        },
      ];
    })
    // api: buy (remote)
    //  - buy token (ALGO)
    .api_(a.buyRemote, (ctcs, toks, addrs, ctc, /***/ recv, inTok, outCap) => {
      return [
        [inTok, [0, pToken]],
        (k) => {
          k(null);
          const r = remote(ctc, { buyRemote: rBuyRemote });
          r.buyRemote
            .ALGO({ apps: ctcs, fees: 6, assets: toks, accounts: addrs })
            .pay(inTok)(recv, inTok, outCap);
          return [s];
        },
      ];
    })
    // api: buy (remote)
    //  - buy (TOKEN)
    .api_(
      a.buyRemoteToken,
      (ctcs, toks, addrs, ctc, /***/ recv, inTok, outCap) => {
        return [
          [0, , [inTok, pToken]],
          (k) => {
            k(null);
            const r = remote(ctc, { buyRemoteToken: rBuyRemoteToken });
            r.buyRemoteToken
              .ALGO({ apps: ctcs, fees: 6, assets: toks, accounts: addrs })
              .pay([[inTok, pToken]])(recv, inTok, outCap);
            return [s];
          },
        ];
      }
    )
    // api: buy (remote)
    //  - safe buy token (TOKEN)
    .api_(
      a.safeBuyRemoteToken,
      (ctcs, toks, addrs, ctc, /***/ recv, inTok, outCap) => {
        return [
          [0, , [inTok, pToken]],
          (k) => {
            k(null);
            const r = remote(ctc, { safeBuyRemoteToken: rSafeBuyRemoteToken });
            r.safeBuyRemoteToken
              .ALGO({ apps: ctcs, fees: 6, assets: toks, accounts: addrs })
              .pay([[inTok, pToken]])(recv, inTok, outCap);
            return [s];
          },
        ];
      }
    )
    // api: close (manager only)
    //  - close contract
    .api_(a.close, () => {
      check(this == s.manager, "only manager can close");
      return [
        (k) => {
          k(null);
          return [
            {
              ...s,
              closed: true,
            },
          ];
        },
      ];
    })
    .timeout(false);
  e.appClose();
  commit();
  exit();
};
// ----------------------------------------------
