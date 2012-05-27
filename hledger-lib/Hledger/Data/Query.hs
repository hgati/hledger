{-|

A general query system for matching things (accounts, postings,
transactions..)  by various criteria, and a parser for query expressions.

-}

module Hledger.Data.Query (
  -- * Query and QueryOpt
  Query(..),
  QueryOpt(..),
  -- * parsing
  parseQuery,
  simplifyQuery,
  filterQuery,
  -- * accessors
  queryIsNull,
  queryIsDepth,
  queryIsDate,
  queryIsStartDateOnly,
  queryStartDate,
  queryDateSpan,
  queryDepth,
  queryEmpty,
  inAccount,
  inAccountQuery,
  -- * matching
  matchesAccount,
  matchesPosting,
  matchesTransaction,
  -- * tests
  tests_Hledger_Data_Query
)
where
import Data.Either
import Data.List
import Data.Maybe
import Data.Time.Calendar
import Safe (readDef, headDef)
import Test.HUnit
import Text.ParserCombinators.Parsec

import Hledger.Utils
import Hledger.Data.Types
import Hledger.Data.AccountName
import Hledger.Data.Amount
import Hledger.Data.Dates
import Hledger.Data.Posting
import Hledger.Data.Transaction


-- | A query is a composition of search criteria, which can be used to
-- match postings, transactions, accounts and more.
data Query = Any              -- ^ always match
           | None             -- ^ never match
           | Not Query        -- ^ negate this match
           | Or [Query]       -- ^ match if any of these match
           | And [Query]      -- ^ match if all of these match
           | Desc String      -- ^ match if description matches this regexp
           | Acct String      -- ^ match postings whose account matches this regexp
           | Date DateSpan    -- ^ match if actual date in this date span
           | EDate DateSpan   -- ^ match if effective date in this date span
           | Status Bool      -- ^ match if cleared status has this value
           | Real Bool        -- ^ match if "realness" (involves a real non-virtual account ?) has this value
           | Empty Bool       -- ^ if true, show zero-amount postings/accounts which are usually not shown
                              --   more of a query option than a query criteria ?
           | Depth Int        -- ^ match if account depth is less than or equal to this value
    deriving (Show, Eq)

-- | A query option changes a query's/report's behaviour and output in some way.
data QueryOpt = QueryOptInAcctOnly AccountName  -- ^ show an account register focussed on this account
              | QueryOptInAcct AccountName      -- ^ as above but include sub-accounts in the account register
           -- | QueryOptCostBasis      -- ^ show amounts converted to cost where possible
           -- | QueryOptEffectiveDate  -- ^ show effective dates instead of actual dates
    deriving (Show, Eq)

-- parsing

-- -- | A query restricting the account(s) to be shown in the sidebar, if any.
-- -- Just looks at the first query option.
-- showAccountMatcher :: [QueryOpt] -> Maybe Query
-- showAccountMatcher (QueryOptInAcctSubsOnly a:_) = Just $ Acct True $ accountNameToAccountRegex a
-- showAccountMatcher _ = Nothing


-- | Convert a query expression containing zero or more space-separated
-- terms to a query and zero or more query options. A query term is either:
--
-- 1. a search pattern, which matches on one or more fields, eg:
--
--      acct:REGEXP     - match the account name with a regular expression
--      desc:REGEXP     - match the transaction description
--      date:PERIODEXP  - match the date with a period expression
--
--    The prefix indicates the field to match, or if there is no prefix
--    account name is assumed.
--
-- 2. a query option, which modifies the reporting behaviour in some
--    way. There is currently one of these, which may appear only once:
--
--      inacct:FULLACCTNAME
--
-- The usual shell quoting rules are assumed. When a pattern contains
-- whitespace, it (or the whole term including prefix) should be enclosed
-- in single or double quotes.
--
-- Period expressions may contain relative dates, so a reference date is
-- required to fully parse these.
--
-- Multiple terms are combined as follows:
-- 1. multiple account patterns are OR'd together
-- 2. multiple description patterns are OR'd together
-- 3. then all terms are AND'd together
parseQuery :: Day -> String -> (Query,[QueryOpt])
parseQuery d s = (q, opts)
  where
    terms = words'' prefixes s
    (pats, opts) = partitionEithers $ map (parseQueryTerm d) terms
    (descpats, pats') = partition queryIsDesc pats
    (acctpats, otherpats) = partition queryIsAcct pats'
    q = simplifyQuery $ And $ [Or acctpats, Or descpats] ++ otherpats

tests_parseQuery = [
  "parseQuery" ~: do
    let d = nulldate -- parsedate "2011/1/1"
    parseQuery d "acct:'expenses:autres d\233penses' desc:b" `is` (And [Acct "expenses:autres d\233penses", Desc "b"], [])
    parseQuery d "inacct:a desc:\"b b\"" `is` (Desc "b b", [QueryOptInAcct "a"])
    parseQuery d "inacct:a inacct:b" `is` (Any, [QueryOptInAcct "a", QueryOptInAcct "b"])
    parseQuery d "desc:'x x'" `is` (Desc "x x", [])
    parseQuery d "'a a' 'b" `is` (Or [Acct "a a",Acct "'b"], [])
    -- parseQuery d "a b desc:x desc:y status:1" `is` 
    --   (And [Or [Acct "a", Acct "b"], Or [Desc "x", Desc "y"], Status True], [])
 ]

-- keep synced with patterns below, excluding "not"
prefixes = map (++":") [
            "inacct","inacctonly",
            "desc","acct","date","edate","status","real","empty","depth"
           ]
defaultprefix = "acct"

-- | Quote-and-prefix-aware version of words - don't split on spaces which
-- are inside quotes, including quotes which may have one of the specified
-- prefixes in front, and maybe an additional not: prefix in front of that.
words'' :: [String] -> String -> [String]
words'' prefixes = fromparse . parsewith maybeprefixedquotedphrases -- XXX
    where
      maybeprefixedquotedphrases = choice' [prefixedQuotedPattern, quotedPattern, pattern] `sepBy` many1 spacenonewline
      prefixedQuotedPattern = do
        not' <- fromMaybe "" `fmap` (optionMaybe $ string "not:")
        let allowednexts | null not' = prefixes
                         | otherwise = prefixes ++ [""]
        next <- choice' $ map string allowednexts
        let prefix = not' ++ next
        p <- quotedPattern
        return $ prefix ++ stripquotes p
      quotedPattern = do
        p <- between (oneOf "'\"") (oneOf "'\"") $ many $ noneOf "'\""
        return $ stripquotes p
      pattern = many (noneOf " \n\r\"")

tests_words'' = [
   "words''" ~: do
    assertEqual "1" ["a","b"]        (words'' [] "a b")
    assertEqual "2" ["a b"]          (words'' [] "'a b'")
    assertEqual "3" ["not:a","b"]    (words'' [] "not:a b")
    assertEqual "4" ["not:a b"]    (words'' [] "not:'a b'")
    assertEqual "5" ["not:a b"]    (words'' [] "'not:a b'")
    assertEqual "6" ["not:desc:a b"]    (words'' ["desc:"] "not:desc:'a b'")
    let s `gives` r = assertEqual "" r (words'' prefixes s)
    "\"acct:expenses:autres d\233penses\"" `gives` ["acct:expenses:autres d\233penses"]
 ]

-- -- | Parse the query string as a boolean tree of match patterns.
-- parseQueryTerm :: String -> Query
-- parseQueryTerm s = either (const (Any)) id $ runParser query () "" $ lexmatcher s

-- lexmatcher :: String -> [String]
-- lexmatcher s = words' s

-- query :: GenParser String () Query
-- query = undefined

-- | Parse a single query term as either a query or a query option.
parseQueryTerm :: Day -> String -> Either Query QueryOpt
parseQueryTerm _ ('i':'n':'a':'c':'c':'t':'o':'n':'l':'y':':':s) = Right $ QueryOptInAcctOnly s
parseQueryTerm _ ('i':'n':'a':'c':'c':'t':':':s) = Right $ QueryOptInAcct s
parseQueryTerm d ('n':'o':'t':':':s) = case parseQueryTerm d s of
                                       Left m  -> Left $ Not m
                                       Right _ -> Left Any -- not:somequeryoption will be ignored
parseQueryTerm _ ('d':'e':'s':'c':':':s) = Left $ Desc s
parseQueryTerm _ ('a':'c':'c':'t':':':s) = Left $ Acct s
parseQueryTerm d ('d':'a':'t':'e':':':s) =
        case parsePeriodExpr d s of Left _ -> Left None -- XXX should warn
                                    Right (_,span) -> Left $ Date span
parseQueryTerm d ('e':'d':'a':'t':'e':':':s) =
        case parsePeriodExpr d s of Left _ -> Left None -- XXX should warn
                                    Right (_,span) -> Left $ EDate span
parseQueryTerm _ ('s':'t':'a':'t':'u':'s':':':s) = Left $ Status $ parseStatus s
parseQueryTerm _ ('r':'e':'a':'l':':':s) = Left $ Real $ parseBool s
parseQueryTerm _ ('e':'m':'p':'t':'y':':':s) = Left $ Empty $ parseBool s
parseQueryTerm _ ('d':'e':'p':'t':'h':':':s) = Left $ Depth $ readDef 0 s
parseQueryTerm _ "" = Left $ Any
parseQueryTerm d s = parseQueryTerm d $ defaultprefix++":"++s

tests_parseQueryTerm = [
  "parseQueryTerm" ~: do
    let s `gives` r = parseQueryTerm nulldate s `is` r
    "a" `gives` (Left $ Acct "a")
    "acct:expenses:autres d\233penses" `gives` (Left $ Acct "expenses:autres d\233penses")
    "not:desc:a b" `gives` (Left $ Not $ Desc "a b")
    "status:1" `gives` (Left $ Status True)
    "status:0" `gives` (Left $ Status False)
    "status:" `gives` (Left $ Status False)
    "real:1" `gives` (Left $ Real True)
    "date:2008" `gives` (Left $ Date $ DateSpan (Just $ parsedate "2008/01/01") (Just $ parsedate "2009/01/01"))
    "date:from 2012/5/17" `gives` (Left $ Date $ DateSpan (Just $ parsedate "2012/05/17") Nothing)
    "inacct:a" `gives` (Right $ QueryOptInAcct "a")
 ]

-- | Parse the boolean value part of a "status:" query, allowing "*" as
-- another way to spell True, similar to the journal file format.
parseStatus :: String -> Bool
parseStatus s = s `elem` (truestrings ++ ["*"])

-- | Parse the boolean value part of a "status:" query. A true value can
-- be spelled as "1", "t" or "true".
parseBool :: String -> Bool
parseBool s = s `elem` truestrings

truestrings :: [String]
truestrings = ["1","t","true"]

simplifyQuery :: Query -> Query
simplifyQuery q =
  let q' = simplify q
  in if q' == q then q else simplifyQuery q'
  where
    simplify (And []) = Any
    simplify (And [q]) = simplify q
    simplify (And qs) | same qs = simplify $ head qs
                      | any (==None) qs = None
                      | all queryIsDate qs = Date $ spansIntersect $ mapMaybe queryTermDateSpan qs
                      | otherwise = And $ concat $ [map simplify dateqs, map simplify otherqs]
                      where (dateqs, otherqs) = partition queryIsDate $ filter (/=Any) qs
    simplify (Or []) = Any
    simplify (Or [q]) = simplifyQuery q
    simplify (Or qs) | same qs = simplify $ head qs
                     | any (==Any) qs = Any
                     -- all queryIsDate qs = Date $ spansUnion $ mapMaybe queryTermDateSpan qs  ?
                     | otherwise = Or $ map simplify $ filter (/=None) qs
    simplify (Date (DateSpan Nothing Nothing)) = Any
    simplify q = q

tests_simplifyQuery = [
 "simplifyQuery" ~: do
  let q `gives` r = assertEqual "" r (simplifyQuery q)
  Or [Acct "a"] `gives` Acct "a"
  Or [Any,None] `gives` Any
  And [Any,None] `gives` None
  And [Any,Any] `gives` Any
  And [Acct "b",Any] `gives` Acct "b"
  And [Any,And [Date (DateSpan Nothing Nothing)]] `gives` Any
  And [Date (DateSpan Nothing (Just $ parsedate "2013-01-01")), Date (DateSpan (Just $ parsedate "2012-01-01") Nothing)]
      `gives` Date (DateSpan (Just $ parsedate "2012-01-01") (Just $ parsedate "2013-01-01"))
  And [Or [],Or [Desc "b b"]] `gives` Desc "b b"
 ]

same [] = True
same (a:as) = all (a==) as

-- | Remove query terms (or whole sub-expressions) not matching the given
-- predicate from this query.  XXX Semantics not yet clear.
filterQuery :: (Query -> Bool) -> Query -> Query
filterQuery p (And qs) = And $ filter p qs
filterQuery p (Or qs) = Or $ filter p qs
-- filterQuery p (Not q) = Not $ filterQuery p q
filterQuery p q = if p q then q else Any

tests_filterQuery = [
 "filterQuery" ~: do
  let (q,p) `gives` r = assertEqual "" r (filterQuery p q)
  (Any, queryIsDepth) `gives` Any
  (Depth 1, queryIsDepth) `gives` Depth 1
  -- (And [Date nulldatespan, Not (Or [Any, Depth 1])], queryIsDepth) `gives` And [Not (Or [Depth 1])]
 ]

-- * accessors

-- | Does this query match everything ?
queryIsNull :: Query -> Bool
queryIsNull Any = True
queryIsNull (And []) = True
queryIsNull (Not (Or [])) = True
queryIsNull _ = False

queryIsDepth :: Query -> Bool
queryIsDepth (Depth _) = True
queryIsDepth _ = False

queryIsDate :: Query -> Bool
queryIsDate (Date _) = True
queryIsDate _ = False

queryIsDesc :: Query -> Bool
queryIsDesc (Desc _) = True
queryIsDesc _ = False

queryIsAcct :: Query -> Bool
queryIsAcct (Acct _) = True
queryIsAcct _ = False

-- | Does this query specify a start date and nothing else (that would
-- filter postings prior to the date) ?
-- When the flag is true, look for a starting effective date instead.
queryIsStartDateOnly :: Bool -> Query -> Bool
queryIsStartDateOnly _ Any = False
queryIsStartDateOnly _ None = False
queryIsStartDateOnly effective (Or ms) = and $ map (queryIsStartDateOnly effective) ms
queryIsStartDateOnly effective (And ms) = and $ map (queryIsStartDateOnly effective) ms
queryIsStartDateOnly False (Date (DateSpan (Just _) _)) = True
queryIsStartDateOnly True (EDate (DateSpan (Just _) _)) = True
queryIsStartDateOnly _ _ = False

-- | What start date (or effective date) does this query specify, if any ?
-- For OR expressions, use the earliest of the dates. NOT is ignored.
queryStartDate :: Bool -> Query -> Maybe Day
queryStartDate effective (Or ms) = earliestMaybeDate $ map (queryStartDate effective) ms
queryStartDate effective (And ms) = latestMaybeDate $ map (queryStartDate effective) ms
queryStartDate False (Date (DateSpan (Just d) _)) = Just d
queryStartDate True (EDate (DateSpan (Just d) _)) = Just d
queryStartDate _ _ = Nothing

queryTermDateSpan (Date span) = Just span
queryTermDateSpan _ = Nothing

-- | What date span (or effective date span) does this query specify ?
-- For OR expressions, use the widest possible span. NOT is ignored.
queryDateSpan :: Bool -> Query -> DateSpan
queryDateSpan effective q = spansUnion $ queryDateSpans effective q

-- | Extract all date (or effective date) spans specified in this query.
-- NOT is ignored.
queryDateSpans :: Bool -> Query -> [DateSpan]
queryDateSpans effective (Or qs) = concatMap (queryDateSpans effective) qs
queryDateSpans effective (And qs) = concatMap (queryDateSpans effective) qs
queryDateSpans False (Date span) = [span]
queryDateSpans True (EDate span) = [span]
queryDateSpans _ _ = []

-- | What is the earliest of these dates, where Nothing is earliest ?
earliestMaybeDate :: [Maybe Day] -> Maybe Day
earliestMaybeDate = headDef Nothing . sortBy compareMaybeDates

-- | What is the latest of these dates, where Nothing is earliest ?
latestMaybeDate :: [Maybe Day] -> Maybe Day
latestMaybeDate = headDef Nothing . sortBy (flip compareMaybeDates)

-- | Compare two maybe dates, Nothing is earliest.
compareMaybeDates :: Maybe Day -> Maybe Day -> Ordering
compareMaybeDates Nothing Nothing = EQ
compareMaybeDates Nothing (Just _) = LT
compareMaybeDates (Just _) Nothing = GT
compareMaybeDates (Just a) (Just b) = compare a b

-- | The depth limit this query specifies, or a large number if none.
queryDepth :: Query -> Int
queryDepth q = case queryDepth' q of [] -> 99999
                                     ds -> minimum ds
  where
    queryDepth' (Depth d) = [d]
    queryDepth' (Or qs) = concatMap queryDepth' qs
    queryDepth' (And qs) = concatMap queryDepth' qs
    queryDepth' _ = []

-- | The empty (zero amount) status specified by this query, defaulting to false.
queryEmpty :: Query -> Bool
queryEmpty = headDef False . queryEmpty'
  where
    queryEmpty' (Empty v) = [v]
    queryEmpty' (Or qs) = concatMap queryEmpty' qs
    queryEmpty' (And qs) = concatMap queryEmpty' qs
    queryEmpty' _ = []

-- -- | The "include empty" option specified by this query, defaulting to false.
-- emptyQueryOpt :: [QueryOpt] -> Bool
-- emptyQueryOpt = headDef False . emptyQueryOpt'
--   where
--     emptyQueryOpt' [] = False
--     emptyQueryOpt' (QueryOptEmpty v:_) = v
--     emptyQueryOpt' (_:vs) = emptyQueryOpt' vs

-- | The account we are currently focussed on, if any, and whether subaccounts are included.
-- Just looks at the first query option.
inAccount :: [QueryOpt] -> Maybe (AccountName,Bool)
inAccount [] = Nothing
inAccount (QueryOptInAcctOnly a:_) = Just (a,False)
inAccount (QueryOptInAcct a:_) = Just (a,True)

-- | A query for the account(s) we are currently focussed on, if any.
-- Just looks at the first query option.
inAccountQuery :: [QueryOpt] -> Maybe Query
inAccountQuery [] = Nothing
inAccountQuery (QueryOptInAcctOnly a:_) = Just $ Acct $ accountNameToAccountOnlyRegex a
inAccountQuery (QueryOptInAcct a:_) = Just $ Acct $ accountNameToAccountRegex a

-- -- | Convert a query to its inverse.
-- negateQuery :: Query -> Query
-- negateQuery =  Not

-- matching

-- | Does the match expression match this account ?
-- A matching in: clause is also considered a match.
matchesAccount :: Query -> AccountName -> Bool
matchesAccount (None) _ = False
matchesAccount (Not m) a = not $ matchesAccount m a
matchesAccount (Or ms) a = any (`matchesAccount` a) ms
matchesAccount (And ms) a = all (`matchesAccount` a) ms
matchesAccount (Acct r) a = regexMatchesCI r a
matchesAccount (Depth d) a = accountNameLevel a <= d
matchesAccount _ _ = True

tests_matchesAccount = [
   "matchesAccount" ~: do
    assertBool "positive acct match" $ matchesAccount (Acct "b:c") "a:bb:c:d"
    -- assertBool "acct should match at beginning" $ not $ matchesAccount (Acct True "a:b") "c:a:b"
    let q `matches` a = assertBool "" $ q `matchesAccount` a
    Depth 2 `matches` "a:b"
    assertBool "" $ Depth 2 `matchesAccount` "a"
    assertBool "" $ Depth 2 `matchesAccount` "a:b"
    assertBool "" $ not $ Depth 2 `matchesAccount` "a:b:c"
    assertBool "" $ Date nulldatespan `matchesAccount` "a"
    assertBool "" $ EDate nulldatespan `matchesAccount` "a"
 ]

-- | Does the match expression match this posting ?
matchesPosting :: Query -> Posting -> Bool
matchesPosting (Not q) p = not $ q `matchesPosting` p
matchesPosting (Any) _ = True
matchesPosting (None) _ = False
matchesPosting (Or qs) p = any (`matchesPosting` p) qs
matchesPosting (And qs) p = all (`matchesPosting` p) qs
matchesPosting (Desc r) p = regexMatchesCI r $ maybe "" tdescription $ ptransaction p
matchesPosting (Acct r) p = regexMatchesCI r $ paccount p
matchesPosting (Date span) p =
    case d of Just d'  -> spanContainsDate span d'
              Nothing -> False
    where d = maybe Nothing (Just . tdate) $ ptransaction p
matchesPosting (EDate span) p =
    case postingEffectiveDate p of Just d  -> spanContainsDate span d
                                   Nothing -> False
matchesPosting (Status v) p = v == postingCleared p
matchesPosting (Real v) p = v == isReal p
matchesPosting (Depth d) Posting{paccount=a} = Depth d `matchesAccount` a
-- matchesPosting (Empty v) Posting{pamount=a} = v == isZeroMixedAmount a
-- matchesPosting (Empty False) Posting{pamount=a} = True
-- matchesPosting (Empty True) Posting{pamount=a} = isZeroMixedAmount a
matchesPosting (Empty _) _ = True
-- matchesPosting _ _ = False

tests_matchesPosting = [
   "matchesPosting" ~: do
    -- matching posting status..
    assertBool "positive match on true posting status"  $
                   (Status True)  `matchesPosting` nullposting{pstatus=True}
    assertBool "negative match on true posting status"  $
               not $ (Not $ Status True)  `matchesPosting` nullposting{pstatus=True}
    assertBool "positive match on false posting status" $
                   (Status False) `matchesPosting` nullposting{pstatus=False}
    assertBool "negative match on false posting status" $
               not $ (Not $ Status False) `matchesPosting` nullposting{pstatus=False}
    assertBool "positive match on true posting status acquired from transaction" $
                   (Status True) `matchesPosting` nullposting{pstatus=False,ptransaction=Just nulltransaction{tstatus=True}}
    assertBool "real:1 on real posting" $ (Real True) `matchesPosting` nullposting{ptype=RegularPosting}
    assertBool "real:1 on virtual posting fails" $ not $ (Real True) `matchesPosting` nullposting{ptype=VirtualPosting}
    assertBool "real:1 on balanced virtual posting fails" $ not $ (Real True) `matchesPosting` nullposting{ptype=BalancedVirtualPosting}
    assertBool "" $ (Acct "'b") `matchesPosting` nullposting{paccount="'b"}
 ]

-- | Does the match expression match this transaction ?
matchesTransaction :: Query -> Transaction -> Bool
matchesTransaction (Not q) t = not $ q `matchesTransaction` t
matchesTransaction (Any) _ = True
matchesTransaction (None) _ = False
matchesTransaction (Or qs) t = any (`matchesTransaction` t) qs
matchesTransaction (And qs) t = all (`matchesTransaction` t) qs
matchesTransaction (Desc r) t = regexMatchesCI r $ tdescription t
matchesTransaction q@(Acct _) t = any (q `matchesPosting`) $ tpostings t
matchesTransaction (Date span) t = spanContainsDate span $ tdate t
matchesTransaction (EDate span) t = spanContainsDate span $ transactionEffectiveDate t
matchesTransaction (Status v) t = v == tstatus t
matchesTransaction (Real v) t = v == hasRealPostings t
matchesTransaction (Empty _) _ = True
matchesTransaction (Depth d) t = any (Depth d `matchesPosting`) $ tpostings t
-- matchesTransaction _ _ = False

tests_matchesTransaction = [
  "matchesTransaction" ~: do
   let q `matches` t = assertBool "" $ q `matchesTransaction` t
   Any `matches` nulltransaction
   assertBool "" $ not $ (Desc "x x") `matchesTransaction` nulltransaction{tdescription="x"}
   assertBool "" $ (Desc "x x") `matchesTransaction` nulltransaction{tdescription="x x"}
 ]

postingEffectiveDate :: Posting -> Maybe Day
postingEffectiveDate p = maybe Nothing (Just . transactionEffectiveDate) $ ptransaction p

-- tests

tests_Hledger_Data_Query :: Test
tests_Hledger_Data_Query = TestList $
    tests_simplifyQuery
 ++ tests_words''
 ++ tests_filterQuery
 ++ tests_parseQueryTerm
 ++ tests_parseQuery
 ++ tests_matchesAccount
 ++ tests_matchesPosting
 ++ tests_matchesTransaction

