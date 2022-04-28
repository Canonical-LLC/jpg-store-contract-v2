{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Canonical.JpgStore.BulkPurchase
  ( Payout(..)
  , Redeemer(..)
  , Swap(..)
  , swap
  , writePlutusFile
  ) where

import Canonical.Shared
import qualified Cardano.Api as Api
import Cardano.Api.Shelley (PlutusScript(..), PlutusScriptV1)
import Codec.Serialise (serialise)
import qualified Data.ByteString.Lazy as LB
import qualified Data.ByteString.Short as SBS
import Ledger
  (Datum(..), DatumHash, PubKeyHash, TxOutRef, mkValidatorScript, ValidatorHash, validatorHash)
import qualified Ledger.Typed.Scripts as Scripts
import Plutus.V1.Ledger.Credential
import Plutus.V1.Ledger.Value
import PlutusTx
import qualified PlutusTx.AssocMap as M
import PlutusTx.AssocMap (Map)
import PlutusTx.Prelude
import Prelude (IO, print, putStrLn)
import System.FilePath

#include "../DebugUtilities.h"

data SwapAddress = SwapAddress
  { aaddressCredential :: Credential
  , aaddressStakingCredential :: BuiltinData
  }

data SwapTxOut = SwapTxOut
  { atxOutAddress :: SwapAddress
  , atxOutValue :: Value
  , atxOutDatumHash :: BuiltinData
  }

data SwapTxInInfo = SwapTxInInfo
  { atxInInfoOutRef :: TxOutRef
  , atxInInfoResolved :: SwapTxOut
  }

data SwapTxInfo = SwapTxInfo
  { atxInfoInputs :: [SwapTxInInfo]
  , atxInfoOutputs :: [SwapTxOut]
  , atxInfoFee :: BuiltinData
  , atxInfoMint :: BuiltinData
  , atxInfoDCert :: BuiltinData
  , atxInfoWdrl :: BuiltinData
  , atxInfoValidRange :: BuiltinData
  , atxInfoSignatories :: [PubKeyHash]
  , atxInfoData :: [(DatumHash, Datum)]
  , atxInfoId :: BuiltinData
  }

{-# HLINT ignore SwapScriptPurpose #-}
data SwapScriptPurpose
    = ASpending TxOutRef

data SwapScriptContext = SwapScriptContext
  { aScriptContextTxInfo :: SwapTxInfo
  , aScriptContextPurpose :: SwapScriptPurpose
  }

valuePaidTo' :: [SwapTxOut] -> PubKeyHash -> Value
valuePaidTo' outs pkh = mconcat (pubKeyOutputsAt' pkh outs)

pubKeyOutputsAt' :: PubKeyHash -> [SwapTxOut] -> [Value]
pubKeyOutputsAt' pk outs =
  let
    flt SwapTxOut { atxOutAddress = SwapAddress (PubKeyCredential pk') _, atxOutValue }
      | pk == pk' = Just atxOutValue
      | otherwise = Nothing
    flt _ = Nothing
  in mapMaybe flt outs

ownHash' :: [SwapTxInInfo] -> TxOutRef -> ValidatorHash
ownHash' ins txOutRef = go ins where
    go = \case
      [] -> TRACE_ERROR("The impossible happened", "-1")
      SwapTxInInfo {..} :xs ->
        if atxInInfoOutRef == txOutRef then
          case atxOutAddress atxInInfoResolved of
            SwapAddress (ScriptCredential s) _ -> s
            _ -> TRACE_ERROR("The impossible happened", "-1")
        else
          go xs

unstableMakeIsData ''SwapTxInfo
unstableMakeIsData ''SwapScriptContext
makeIsDataIndexed  ''SwapScriptPurpose [('ASpending,1)]
unstableMakeIsData ''SwapAddress
unstableMakeIsData ''SwapTxOut
unstableMakeIsData ''SwapTxInInfo

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

data Payout = Payout
  { pAddress :: !PubKeyHash
  , pValue :: !Value
  }

data Swap = Swap
  { sOwner :: !PubKeyHash
  -- ^ Used for the signer check on Cancel
  , sSwapValue :: !Value
  -- ^ Value the owner is offering up
  , sSwapPayouts :: ![Payout]
  -- ^ Divvy up the payout to different address for Swap
  }

data Redeemer
  = Cancel
  | Accept


-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------
isScriptAddress :: SwapAddress -> Bool
isScriptAddress SwapAddress { aaddressCredential } = case aaddressCredential of
  ScriptCredential _ -> True
  _ -> False

isScriptInput :: SwapTxInInfo -> Bool
isScriptInput txIn = isScriptAddress (atxOutAddress  (atxInInfoResolved txIn))

onlyThisTypeOfScript :: ValidatorHash -> [SwapTxInInfo] -> Bool
onlyThisTypeOfScript thisValidator = go where
  go = \case
    [] -> True
    SwapTxInInfo
      { atxInInfoResolved = SwapTxOut
        { atxOutAddress = SwapAddress
          { aaddressCredential = ScriptCredential vh
          }
        }
      } : xs ->  if vh == thisValidator then
              go xs
            else
              TRACE_IF_FALSE("Bad validator input", "100", False)
    _ : xs -> go xs

mapInsertWith :: Eq k => (a -> a -> a) -> k -> a -> Map k a -> Map k a
mapInsertWith f k v xs = case M.lookup k xs of
  Nothing -> M.insert k v xs
  Just v' -> M.insert k (f v v') xs

mergePayouts :: Payout -> Map PubKeyHash Value -> Map PubKeyHash Value
mergePayouts Payout {..} =
  mapInsertWith (+) pAddress pValue

paidAtleastTo :: [SwapTxOut] -> PubKeyHash -> Value -> Bool
paidAtleastTo outputs pkh val = valuePaidTo' outputs pkh `geq` val
-------------------------------------------------------------------------------
-- Boilerplate
-------------------------------------------------------------------------------
instance Eq Payout where
  x == y = pAddress x == pAddress y && pValue x == pValue y

instance Eq Swap where
  x == y =
    sOwner x
      == sOwner y
      && sSwapValue x
      == sSwapValue y
      && sSwapPayouts x
      == sSwapPayouts y

instance Eq Redeemer where
  x == y = case (x, y) of
    (Cancel, Cancel) -> True
    (Cancel, _) -> False
    (Accept, Accept) -> True
    (Accept, _) -> False

PlutusTx.unstableMakeIsData ''Payout
PlutusTx.unstableMakeIsData ''Swap
PlutusTx.unstableMakeIsData ''Redeemer

-------------------------------------------------------------------------------
-- Validation
-------------------------------------------------------------------------------
-- check that each user is paid
-- and the total is correct
{-# HLINT ignore validateOutputConstraints "Use uncurry" #-}
validateOutputConstraints :: [SwapTxOut] -> Map PubKeyHash Value -> Bool
validateOutputConstraints outputs constraints = all (\(pkh, v) -> paidAtleastTo outputs pkh v) (M.toList constraints)

-- Every branch but user initiated cancel requires checking the input
-- to ensure there is only one script input.
swapValidator :: Swap -> Redeemer -> SwapScriptContext -> Bool
swapValidator _ r SwapScriptContext{aScriptContextTxInfo = SwapTxInfo{..}, aScriptContextPurpose = ASpending thisOutRef} =
  let
    singleSigner :: PubKeyHash
    singleSigner = case atxInfoSignatories of
      [x] -> x
      _ -> TRACE_ERROR("single signer expected", "1")

    thisValidator :: ValidatorHash
    thisValidator = ownHash' atxInfoInputs thisOutRef

    convertDatum :: forall a. DataConstraint(a) => Datum -> a
    convertDatum d =
      let a = getDatum d
       in FROM_BUILT_IN_DATA("found datum that is not a swap", "2", a)

    swaps :: [Swap]
    swaps = fmap (\(_, d) -> convertDatum d) atxInfoData

    outputsAreValid :: Map PubKeyHash Value -> Bool
    outputsAreValid = validateOutputConstraints atxInfoOutputs

    foldSwaps :: (Swap -> a -> a) -> a -> a
    foldSwaps f init = foldr f init swaps
  -- This allows the script to validate all inputs and outputs on only one script input.
  -- Ignores other script inputs being validated each time
  in if atxInInfoOutRef (head (filter isScriptInput atxInfoInputs)) /= thisOutRef then True else
    TRACE_IF_FALSE("Not the only type of script", "3", (onlyThisTypeOfScript thisValidator atxInfoInputs))
    && case r of
      Cancel ->
        let
          signerIsOwner Swap{sOwner} = singleSigner == sOwner
        in
          TRACE_IF_FALSE("signer is not the owner", "4", (all signerIsOwner swaps))

      Accept ->
        -- Acts like a Buy, but we ignore any payouts that go to the signer of the
        -- transaction. This allows the seller to accept an offer from a buyer that
        -- does not pay the seller as much as they requested
        let
          accumPayouts Swap{..} acc
            | sOwner == singleSigner = acc
            | otherwise = foldr mergePayouts acc sSwapPayouts     

          -- assume all redeemers are accept, all the payouts should be paid (excpet those to the signer)
          payouts :: Map PubKeyHash Value
          payouts = foldSwaps accumPayouts mempty
        in TRACE_IF_FALSE("wrong output", "5", (outputsAreValid payouts))
-------------------------------------------------------------------------------
-- Entry Points
-------------------------------------------------------------------------------

swapWrapped :: BuiltinData -> BuiltinData -> BuiltinData -> ()
swapWrapped = wrap swapValidator

validator :: Scripts.Validator
validator = mkValidatorScript $$(PlutusTx.compile [|| swapWrapped ||])

swap :: PlutusScript PlutusScriptV1
swap = PlutusScriptSerialised . SBS.toShort . LB.toStrict . serialise $ validator

swapHash :: ValidatorHash
swapHash = validatorHash validator

writePlutusFile :: FilePath -> IO ()
writePlutusFile filePath = Api.writeFileTextEnvelope filePath Nothing swap >>= \case
  Left err -> print $ Api.displayError err
  Right () -> putStrLn $ "wrote NFT validator to file " ++ filePath
