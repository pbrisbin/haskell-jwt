{-# LANGUAGE EmptyDataDecls     #-}
{-# LANGUAGE FlexibleInstances  #-}
{-# LANGUAGE GADTs              #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}
{-# LANGUAGE RecordWildCards    #-}
{-# LANGUAGE StandaloneDeriving #-}

{-|
Module:      Web.JWT
License:     MIT
Maintainer:  Stefan Saasen <stefan@saasen.me>
Stability:   experimental

This implementation of JWT is based on <https://tools.ietf.org/html/rfc7519>
but currently only implements the minimum required to work with the Atlassian Connect framework.

Known limitations:

   * Only HMAC SHA-256 algorithm is currently a supported signature algorithm

   * There is currently no verification of time related information
   ('exp', 'nbf', 'iat').

   * Registered claims are not validated
-}
module Web.JWT
    (
    -- * Encoding & Decoding JWTs
    -- ** Decoding
    -- $docDecoding
      decode
    , verify
    , decodeAndVerifySignature
    -- ** Encoding
    , encodeSigned
    , encodeUnsigned

    -- * Utility functions
    -- ** Common
    , tokenIssuer
    , secret
    , binarySecret
    , rsaKeySecret
    -- ** JWT structure
    , claims
    , header
    , signature
    -- ** JWT claims set
    , auds
    , intDate
    , numericDate
    , stringOrURI
    , stringOrURIToText
    , secondsSinceEpoch
    -- ** JWT header
    , typ
    , cty
    , alg

    -- * Types
    , UnverifiedJWT
    , VerifiedJWT
    , Signature
    , Secret
    , JWT
    , JSON
    , Algorithm(..)
    , JWTClaimsSet(..)
    , ClaimsMap
    , IntDate
    , NumericDate
    , StringOrURI
    , JWTHeader
    , JOSEHeader

    , module Data.Default
    ) where

import qualified Data.ByteString.Lazy.Char8 as BL (fromStrict, toStrict)
import qualified Data.ByteString.Extended as BS
import qualified Data.Text.Extended         as T
import qualified Data.Text.Encoding         as TE

import           Codec.Crypto.RSA           (PrivateKey(..), PublicKey(..), sign)
import           Control.Applicative
import           Control.Monad
import           Crypto.Hash.Algorithms
import           Crypto.MAC.HMAC
import           Data.ByteArray.Encoding
import           Data.Aeson                 hiding (decode, encode)
import qualified Data.Aeson                 as JSON
import           Data.Default
import qualified Data.HashMap.Strict        as StrictMap
import qualified Data.Map                   as Map
import           Data.Maybe
import           Data.Scientific
import           Data.Time.Clock            (NominalDiffTime)
import qualified Network.URI                as URI
import           OpenSSL.EVP.PKey           (toKeyPair)
import           OpenSSL.PEM                (PemPasswordSupply(..), readPrivateKey)
import           OpenSSL.RSA
    ( RSAKeyPair
    , RSAPubKey
    , rsaCopyPublic
    , rsaD
    , rsaDMP1
    , rsaDMQ1
    , rsaE
    , rsaIQMP
    , rsaN
    , rsaP
    , rsaQ
    , rsaSize
    )
import           Prelude                    hiding (exp)

-- $setup
-- The code examples in this module require GHC's `OverloadedStrings`
-- extension:
--
-- >>> :set -XOverloadedStrings

type JSON = T.Text

{-# DEPRECATED JWTHeader "Use JOSEHeader instead. JWTHeader will be removed in 1.0" #-}
type JWTHeader = JOSEHeader

-- | The secret used for calculating the message signature
data Secret
    = Secret BS.ByteString -- ^ A textual key, for use with @'HS256'@
    | RSAKey PrivateKey    -- ^ An RSA Private key, for use with @'RS256'@

instance Show Secret where
    show _ = "<secret>"

newtype Signature = Signature T.Text deriving (Show)

instance Eq Signature where
    (Signature s1) == (Signature s2) = s1 `T.constTimeCompare` s2

-- | JSON Web Token without signature verification
data UnverifiedJWT

-- | JSON Web Token that has been successfully verified
data VerifiedJWT


-- | The JSON Web Token
data JWT r where
   Unverified :: JWTHeader -> JWTClaimsSet -> Signature -> T.Text -> JWT UnverifiedJWT
   Verified   :: JWTHeader -> JWTClaimsSet -> Signature -> JWT VerifiedJWT

deriving instance Show (JWT r)

-- | Extract the claims set from a JSON Web Token
claims :: JWT r -> JWTClaimsSet
claims (Unverified _ c _ _) = c
claims (Verified _ c _) = c

-- | Extract the header from a JSON Web Token
header :: JWT r -> JOSEHeader
header (Unverified h _ _ _) = h
header (Verified h _ _) = h

-- | Extract the signature from a verified JSON Web Token
signature :: JWT r -> Maybe Signature
signature Unverified{}     = Nothing
signature (Verified _ _ s) = Just s

-- | A JSON numeric value representing the number of seconds from
-- 1970-01-01T0:0:0Z UTC until the specified UTC date/time.
{-# DEPRECATED IntDate "Use NumericDate instead. IntDate will be removed in 1.0" #-}
type IntDate = NumericDate

-- | A JSON numeric value representing the number of seconds from
-- 1970-01-01T0:0:0Z UTC until the specified UTC date/time.
newtype NumericDate = NumericDate Integer deriving (Show, Eq, Ord)


-- | Return the seconds since 1970-01-01T0:0:0Z UTC for the given 'IntDate'
secondsSinceEpoch :: NumericDate -> NominalDiffTime
secondsSinceEpoch (NumericDate s) = fromInteger s

-- | A JSON string value, with the additional requirement that while
-- arbitrary string values MAY be used, any value containing a ":"
-- character MUST be a URI [RFC3986].  StringOrURI values are
-- compared as case-sensitive strings with no transformations or
-- canonicalizations applied.
data StringOrURI = S T.Text | U URI.URI deriving (Eq)

instance Show StringOrURI where
    show (S s) = T.unpack s
    show (U u) = show u

data Algorithm = HS256 -- ^ HMAC using SHA-256 hash algorithm
               | RS256 -- ^ RSA using SHA-256 hash algorithm
                 deriving (Eq, Show)

-- | JOSE Header, describes the cryptographic operations applied to the JWT
data JOSEHeader = JOSEHeader {
    -- | The typ (type) Header Parameter defined by [JWS] and [JWE] is used to
    -- declare the MIME Media Type [IANA.MediaTypes] of this complete JWT in
    -- contexts where this is useful to the application.
    -- This parameter has no effect upon the JWT processing.
    typ :: Maybe T.Text
    -- | The cty (content type) Header Parameter defined by [JWS] and [JWE] is
    -- used by this specification to convey structural information about the JWT.
  , cty :: Maybe T.Text
    -- | The alg (algorithm) used for signing the JWT. The HS256 (HMAC using SHA-256)
    -- is the only required algorithm and the only one supported in this implementation
    -- in addition to "none" which means that no signature will be used.
    --
    -- See <http://tools.ietf.org/html/draft-ietf-jose-json-web-algorithms-23#page-6>
  , alg :: Maybe Algorithm
} deriving (Eq, Show)

instance Default JOSEHeader where
    def = JOSEHeader Nothing Nothing Nothing

-- | The JWT Claims Set represents a JSON object whose members are the claims conveyed by the JWT.
data JWTClaimsSet = JWTClaimsSet {
    -- Registered Claim Names
    -- http://self-issued.info/docs/draft-ietf-oauth-json-web-token.html#ClaimsContents

    -- | The iss (issuer) claim identifies the principal that issued the JWT.
    iss                :: Maybe StringOrURI

    -- | The sub (subject) claim identifies the principal that is the subject of the JWT.
  , sub                :: Maybe StringOrURI

    -- | The aud (audience) claim identifies the audiences that the JWT is intended for according to draft 18 of the JWT spec, the aud claim is option and may be present in singular or as a list.
  , aud                :: Maybe (Either StringOrURI [StringOrURI])

    -- | The exp (expiration time) claim identifies the expiration time on or after which the JWT MUST NOT be accepted for processing. Its value MUST be a number containing an IntDate value.
  , exp                :: Maybe IntDate

    -- | The nbf (not before) claim identifies the time before which the JWT MUST NOT be accepted for processing.
  , nbf                :: Maybe IntDate

    -- | The iat (issued at) claim identifies the time at which the JWT was issued.
  , iat                :: Maybe IntDate

    -- | The jti (JWT ID) claim provides a unique identifier for the JWT.
  , jti                :: Maybe StringOrURI

  , unregisteredClaims :: ClaimsMap

} deriving (Show, Eq)


instance Default JWTClaimsSet where
    def = JWTClaimsSet Nothing Nothing Nothing Nothing Nothing Nothing Nothing Map.empty


-- | Encode a claims set using the given secret
--
--  @
--  let
--      cs = def { -- def returns a default JWTClaimsSet
--         iss = stringOrURI "Foo"
--       , unregisteredClaims = Map.fromList [("http://example.com/is_root", (Bool True))]
--      }
--      key = secret "secret-key"
--  in encodeSigned HS256 key cs
-- @
-- > "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJodHRwOi8vZXhhbXBsZS5jb20vaXNfcm9vdCI6dHJ1ZSwiaXNzIjoiRm9vIn0.vHQHuG3ujbnBUmEp-fSUtYxk27rLiP2hrNhxpyWhb2E"
encodeSigned :: Algorithm -> Secret -> JWTClaimsSet -> JSON
encodeSigned algo secret claims = dotted [header, claim, signature]
    where claim     = encodeJWT claims
          header    = encodeJWT def {
                        typ = Just "JWT"
                      , alg = Just algo
                      }
          signature = calculateDigest algo secret (dotted [header, claim])

-- | Encode a claims set without signing it
--
--  @
--  let
--      cs = def { -- def returns a default JWTClaimsSet
--      iss = stringOrURI "Foo"
--    , iat = numericDate 1394700934
--    , unregisteredClaims = Map.fromList [("http://example.com/is_root", (Bool True))]
--  }
--  in encodeUnsigned cs
--  @
-- > "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpYXQiOjEzOTQ3MDA5MzQsImh0dHA6Ly9leGFtcGxlLmNvbS9pc19yb290Ijp0cnVlLCJpc3MiOiJGb28ifQ."
encodeUnsigned :: JWTClaimsSet -> JSON
encodeUnsigned claims = dotted [header, claim, ""]
    where claim     = encodeJWT claims
          header    = encodeJWT def {
                        typ = Just "JWT"
                      , alg = Just HS256
                      }

-- | Decode a claims set without verifying the signature. This is useful if
-- information from the claim set is required in order to verify the claim
-- (e.g. the secret needs to be retrieved based on unverified information
-- from the claims set).
--
-- >>> :{
--  let
--      input = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzb21lIjoicGF5bG9hZCJ9.Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U" :: T.Text
--      mJwt = decode input
--  in fmap header mJwt
-- :}
-- Just (JOSEHeader {typ = Just "JWT", cty = Nothing, alg = Just HS256})
--
-- and
--
-- >>> :{
--  let
--      input = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzb21lIjoicGF5bG9hZCJ9.Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U" :: T.Text
--      mJwt = decode input
--  in fmap claims mJwt
-- :}
-- Just (JWTClaimsSet {iss = Nothing, sub = Nothing, aud = Nothing, exp = Nothing, nbf = Nothing, iat = Nothing, jti = Nothing, unregisteredClaims = fromList [("some",String "payload")]})
decode :: JSON -> Maybe (JWT UnverifiedJWT)
decode input = do
    (h,c,s) <- extractElems $ T.splitOn "." input
    let header' = parseJWT h
        claims' = parseJWT c
    Unverified <$> header' <*> claims' <*> (pure . Signature $ s) <*> (pure . dotted $ [h,c])
    where
        extractElems (h:c:s:_) = Just (h,c,s)
        extractElems _         = Nothing

-- | Using a known secret and a decoded claims set verify that the signature is correct
-- and return a verified JWT token as a result.
--
-- This will return a VerifiedJWT if and only if the signature can be verified using the
-- given secret.
--
-- The separation between decode and verify is very useful if you are communicating with
-- multiple different services with different secrets and it allows you to lookup the
-- correct secret for the unverified JWT before trying to verify it. If this is not an
-- isuse for you (there will only ever be one secret) then you should just use
-- 'decodeAndVerifySignature'.
--
-- >>> :{
--  let
--      input = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzb21lIjoicGF5bG9hZCJ9.Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U" :: T.Text
--      mUnverifiedJwt = decode input
--      mVerifiedJwt = verify (secret "secret") =<< mUnverifiedJwt
--  in signature =<< mVerifiedJwt
-- :}
-- Just (Signature "Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U")
verify :: Secret -> JWT UnverifiedJWT -> Maybe (JWT VerifiedJWT)
verify secret' (Unverified header' claims' unverifiedSignature originalClaim) = do
   algo <- alg header'
   let calculatedSignature = Signature $ calculateDigest algo secret' originalClaim
   guard (unverifiedSignature == calculatedSignature)
   pure $ Verified header' claims' calculatedSignature

-- | Decode a claims set and verify that the signature matches by using the supplied secret.
-- The algorithm is based on the supplied header value.
--
-- This will return a VerifiedJWT if and only if the signature can be verified
-- using the given secret.
--
-- >>> :{
--  let
--      input = "eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJzb21lIjoicGF5bG9hZCJ9.Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U" :: T.Text
--      mJwt = decodeAndVerifySignature (secret "secret") input
--  in signature =<< mJwt
-- :}
-- Just (Signature "Joh1R2dYzkRvDkqv3sygm5YyK8Gi4ShZqbhK2gxcs2U")
decodeAndVerifySignature :: Secret -> JSON -> Maybe (JWT VerifiedJWT)
decodeAndVerifySignature secret' input = verify secret' =<< decode input

-- | Try to extract the value for the issue claim field 'iss' from the web token in JSON form
tokenIssuer :: JSON -> Maybe StringOrURI
tokenIssuer = decode >=> fmap pure claims >=> iss

-- | Create a Secret using the given key.
-- Consider using `binarySecret` instead if your key is not already a "Data.Text".
secret :: T.Text -> Secret
secret = Secret . TE.encodeUtf8

-- | Create a Secret using the given key.
binarySecret :: BS.ByteString -> Secret
binarySecret = Secret

-- | Create an RSAKey from PEM contents
--
-- > rsaKeySecret =<< readFile "foo.pem"
--
rsaKeySecret :: String -> IO (Maybe Secret)
rsaKeySecret k = do
    mKeyPair <- toKeyPair <$> readPrivateKey k PwNone
    mPublicKey <- mapM rsaCopyPublic mKeyPair
    return $ RSAKey <$>
        (fromRSAKey <$> mKeyPair <*> mPublicKey)
  where
    fromRSAKey :: RSAKeyPair -> RSAPubKey -> PrivateKey
    fromRSAKey kp pk = PrivateKey
        { private_pub = PublicKey
            { public_size = rsaSize pk
            , public_n = rsaN pk
            , public_e = rsaE pk
            }
        , private_d = rsaD kp
        , private_p = rsaP kp
        , private_q = rsaQ kp
        , private_dP = fromMaybe 0 $ rsaDMP1 kp
        , private_dQ = fromMaybe 0 $ rsaDMQ1 kp
        , private_qinv = fromMaybe 0 $ rsaIQMP kp
        }

-- | Convert the `NominalDiffTime` into an IntDate. Returns a Nothing if the
-- argument is invalid (e.g. the NominalDiffTime must be convertible into a
-- positive Integer representing the seconds since epoch).
{-# DEPRECATED intDate "Use numericDate instead. intDate will be removed in 1.0" #-}
intDate :: NominalDiffTime -> Maybe IntDate
intDate = numericDate

-- | Convert the `NominalDiffTime` into an NumericDate. Returns a Nothing if the
-- argument is invalid (e.g. the NominalDiffTime must be convertible into a
-- positive Integer representing the seconds since epoch).
numericDate :: NominalDiffTime -> Maybe NumericDate
numericDate i | i < 0 = Nothing
numericDate i         = Just $ NumericDate $ round i

-- | Convert a `T.Text` into a 'StringOrURI`. Returns a Nothing if the
-- String cannot be converted (e.g. if the String contains a ':' but is
-- *not* a valid URI).
stringOrURI :: T.Text -> Maybe StringOrURI
stringOrURI t | URI.isURI $ T.unpack t = U <$> URI.parseURI (T.unpack t)
stringOrURI t                          = Just (S t)


-- | Convert a `StringOrURI` into a `T.Text`. Returns the T.Text
-- representing the String as-is or a Text representation of the URI
-- otherwise.
stringOrURIToText :: StringOrURI -> T.Text
stringOrURIToText (S t)   = t
stringOrURIToText (U uri) = T.pack $ URI.uriToString id uri (""::String)

-- | Convert the `aud` claim in a `JWTClaimsSet` into a `[StringOrURI]`
auds :: JWTClaimsSet -> [StringOrURI]
auds jwt = case aud jwt of
    Nothing         -> []
    Just (Left a)   -> [a]
    Just (Right as) -> as

-- =================================================================================

encodeJWT :: ToJSON a => a -> T.Text
encodeJWT = TE.decodeUtf8 . convertToBase Base64URLUnpadded . BL.toStrict . JSON.encode

parseJWT :: FromJSON a => T.Text -> Maybe a
parseJWT x = case convertFromBase Base64URLUnpadded $ TE.encodeUtf8 x of
               Left _  -> Nothing
               Right s -> JSON.decode $ BL.fromStrict s

dotted :: [T.Text] -> T.Text
dotted = T.intercalate "."


-- =================================================================================

calculateDigest :: Algorithm -> Secret -> T.Text -> T.Text
calculateDigest HS256 (Secret key) msg =
    TE.decodeUtf8 $ convertToBase Base64URLUnpadded (hmac key (TE.encodeUtf8 msg) :: HMAC SHA256)

calculateDigest RS256 (RSAKey key) msg = TE.decodeUtf8
    $ convertToBase Base64URLUnpadded
    $ BL.toStrict
    $ sign key
    $ BL.fromStrict
    $ TE.encodeUtf8 msg

calculateDigest _ _ _ = error "Invalid use of calculateDigest"

-- =================================================================================

type ClaimsMap = Map.Map T.Text Value

fromHashMap :: Object -> ClaimsMap
fromHashMap = Map.fromList . StrictMap.toList

removeRegisteredClaims :: ClaimsMap -> ClaimsMap
removeRegisteredClaims input = Map.differenceWithKey (\_ _ _ -> Nothing) input registeredClaims
    where 
        registeredClaims = Map.fromList $ map (\e -> (e, Null)) ["iss", "sub", "aud", "exp", "nbf", "iat", "jti"]

instance ToJSON JWTClaimsSet where
    toJSON JWTClaimsSet{..} = object $ catMaybes [
                  fmap ("iss" .=) iss
                , fmap ("sub" .=) sub
                , either ("aud" .=) ("aud" .=) <$> aud
                , fmap ("exp" .=) exp
                , fmap ("nbf" .=) nbf
                , fmap ("iat" .=) iat
                , fmap ("jti" .=) jti
            ] ++ Map.toList (removeRegisteredClaims unregisteredClaims)

instance FromJSON JWTClaimsSet where
        parseJSON = withObject "JWTClaimsSet"
                     (\o -> JWTClaimsSet
                     <$> o .:? "iss"
                     <*> o .:? "sub"
                     <*> case StrictMap.lookup "aud" o of
                         (Just as@(JSON.Array _)) -> Just <$> Right <$> parseJSON as
                         (Just (JSON.String t))   -> pure $ Left <$> stringOrURI t
                         _                        -> pure Nothing
                     <*> o .:? "exp"
                     <*> o .:? "nbf"
                     <*> o .:? "iat"
                     <*> o .:? "jti"
                     <*> pure (removeRegisteredClaims $ fromHashMap o))

instance FromJSON JOSEHeader where
    parseJSON = withObject "JOSEHeader"
                    (\o -> JOSEHeader
                    <$> o .:? "typ"
                    <*> o .:? "cty"
                    <*> o .:? "alg")

instance ToJSON JOSEHeader where
    toJSON JOSEHeader{..} = object $ catMaybes [
                  fmap ("typ" .=) typ
                , fmap ("cty" .=) cty
                , fmap ("alg" .=) alg
            ]

instance ToJSON NumericDate where
    toJSON (NumericDate i) = Number $ scientific (fromIntegral i) 0

instance FromJSON NumericDate where
    parseJSON (Number x) = return $ NumericDate $ coefficient x
    parseJSON _          = mzero

instance ToJSON Algorithm where
    toJSON HS256 = String ("HS256"::T.Text)
    toJSON RS256 = String ("RS256"::T.Text)

instance FromJSON Algorithm where
    parseJSON (String "HS256") = return HS256
    parseJSON (String "RS256") = return RS256
    parseJSON _                = mzero

instance ToJSON StringOrURI where
    toJSON (S s)   = String s
    toJSON (U uri) = String $ T.pack $ URI.uriToString id uri ""

instance FromJSON StringOrURI where
    parseJSON (String s) | URI.isURI $ T.unpack s = return $ U $ fromMaybe URI.nullURI $ URI.parseURI $ T.unpack s
    parseJSON (String s)                          = return $ S s
    parseJSON _                                   = mzero

-- $docDecoding
-- There are three use cases supported by the set of decoding/verification
-- functions:
--
-- (1) Unsecured JWTs (<http://tools.ietf.org/html/draft-ietf-oauth-json-web-token-30#section-6>).
--      This is supported by the decode function 'decode'.
--      As a client you don't care about signing or encrypting so you only get back a 'JWT' 'UnverifiedJWT'.
--      I.e. the type makes it clear that no signature verification was attempted.
--
-- (2) Signed JWTs you want to verify using a known secret.
--      This is what 'decodeAndVerifySignature' supports, given a secret
--      and JSON it will return a 'JWT' 'VerifiedJWT' if the signature can be
--      verified.
--
-- (3) Signed JWTs that need to be verified using a secret that depends on
--      information contained in the JWT. E.g. the secret depends on
--      some claim, therefore the JWT needs to be decoded first and after
--      retrieving the appropriate secret value, verified in a subsequent step.
--      This is supported by using the `verify` function which given
--      a 'JWT' 'UnverifiedJWT' and a secret will return a 'JWT' 'VerifiedJWT' iff the
--      signature can be verified.
