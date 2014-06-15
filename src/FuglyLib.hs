module FuglyLib
       (
         initFugly,
         stopFugly,
         loadDict,
         saveDict,
         dictLookup,
         insertName,
         insertWord,
         insertWordRaw,
         insertWords,
         dropWord,
         ageWord,
         ageWords,
         listWords,
         listWordFull,
         listWordsCountSort,
         listWordsCountSort2,
         listNamesCountSort2,
         wordIs,
         cleanStringWhite,
         cleanStringBlack,
         cleanString,
         wnRelated,
         wnClosure,
         wnMeet,
         asReplaceWords,
         -- gfAll,
         -- gfRandom,
         gfParseBool,
         gfParseC,
         gfCategories,
         -- gfTranslate,
         sentence,
         chooseWord,
         findRelated,
         joinWords,
         toUpperSentence,
         endSentence,
         dePlenk,
         fHead,
         fLast,
         fTail,
         Word (..),
         Fugly (..)
       )
       where

import Control.Concurrent
import Control.Exception
import qualified Data.ByteString.Char8 as ByteString
import Data.Char
import Data.Either
import Data.List
import qualified Data.Map.Strict as Map
import Data.Maybe
import Data.Tree (flatten)
import qualified System.Random as Random
import System.IO
import System.IO.Error
import System.IO.Unsafe
import Text.Regex.Posix

import qualified Language.Aspell as Aspell
import qualified Language.Aspell.Options as Aspell.Options

import NLP.WordNet hiding (Word)
import NLP.WordNet.Prims (indexLookup, senseCount, getSynset, getWords, getGloss)
import NLP.WordNet.PrimTypes

import PGF

data Fugly = Fugly {
              dict    :: Map.Map String Word,
              pgf     :: PGF,
              wne     :: WordNetEnv,
              aspell  :: Aspell.SpellChecker,
              allow   :: [String],
              ban     :: [String]
              }

data Word = Word {
              word    :: String,
              count   :: Int,
              before  :: Map.Map String Int,
              after   :: Map.Map String Int,
              related :: [String],
              pos     :: EPOS
              } |
            Name {
              name    :: String,
              count   :: Int,
              before  :: Map.Map String Int,
              after   :: Map.Map String Int,
              related :: [String]
              } |
            Place {
              place   :: String,
              count   :: Int,
              before  :: Map.Map String Int,
              after   :: Map.Map String Int,
              related :: [String]
              } |
            Phrase {
              phrase  :: String,
              count   :: Int,
              before  :: Map.Map String Int,
              after   :: Map.Map String Int,
              related :: [String]
              }

initFugly :: FilePath -> FilePath -> FilePath -> String -> IO Fugly
initFugly fuglydir wndir gfdir topic = do
    (dict, allow, ban) <- catchIOError (loadDict fuglydir topic)
                          (const $ return (Map.empty, [], []))
    pgf <- readPGF (gfdir ++ "/ParseEng.pgf")
    wne <- NLP.WordNet.initializeWordNetWithOptions
           (return wndir :: Maybe FilePath)
           (Just (\e f -> putStrLn (e ++ show (f :: SomeException))))
    a <- Aspell.spellCheckerWithOptions [Aspell.Options.Lang (ByteString.pack "en_US"),
                                         Aspell.Options.IgnoreCase False, Aspell.Options.Size Aspell.Options.Large,
                                         Aspell.Options.SuggestMode Aspell.Options.Normal]
    let aspell = head $ rights [a]
    return (Fugly dict pgf wne aspell allow ban)

stopFugly :: FilePath -> Fugly -> String -> IO ()
stopFugly fuglydir fugly@(Fugly _ _ wne _ _ _) topic = do
    catchIOError (saveDict fugly fuglydir topic) (const $ return ())
    closeWordNet wne

saveDict :: Fugly -> FilePath -> String -> IO ()
saveDict fugly@(Fugly dict _ _ _ allow ban) fuglydir topic = do
    let d = Map.toList dict
    if null d then putStrLn "Empty dict!"
      else do
        h <- openFile (fuglydir ++ "/" ++ topic ++ "-dict.txt") WriteMode
        hSetBuffering h LineBuffering
        putStrLn "Saving dict file..."
        saveDict' h d
        hPutStrLn h ">END<"
        hPutStrLn h $ unwords $ sort allow
        hPutStrLn h $ unwords $ sort ban
        hClose h
  where
    saveDict' :: Handle -> [(String, Word)] -> IO ()
    saveDict' _ [] = return ()
    saveDict' h (x:xs) = do
      let l = format' $ snd x
      if null l then return () else hPutStr h l
      saveDict' h xs
    format' m@(Word w c b a r p)
      | null w    = []
      | otherwise = unwords [("word: " ++ w ++ "\n"),
                             ("count: " ++ (show c) ++ "\n"),
                             ("before: " ++ (unwords $ listNeigh2 b) ++ "\n"),
                             ("after: " ++ (unwords $ listNeigh2 a) ++ "\n"),
                             ("related: " ++ (unwords r) ++ "\n"),
                             ("pos: " ++ (show p) ++ "\n"),
                             ("end: \n")]
    format' m@(Name w c b a r)
      | null w    = []
      | otherwise = unwords [("name: " ++ w ++ "\n"),
                             ("count: " ++ (show c) ++ "\n"),
                             ("before: " ++ (unwords $ listNeigh2 b) ++ "\n"),
                             ("after: " ++ (unwords $ listNeigh2 a) ++ "\n"),
                             ("related: " ++ (unwords r) ++ "\n"),
                             ("end: \n")]

loadDict :: FilePath -> String -> IO (Map.Map String Word, [String], [String])
loadDict fuglydir topic = do
    let w = (Word [] 0 Map.empty Map.empty [] UnknownEPos)
    h <- openFile (fuglydir ++ "/" ++ topic ++ "-dict.txt") ReadMode
    eof <- hIsEOF h
    if eof then
      return (Map.empty, [], [])
      else do
      hSetBuffering h LineBuffering
      putStrLn "Loading dict file..."
      dict <- ff h w [([], w)]
      allow <- hGetLine h
      ban <- hGetLine h
      let out = (Map.fromList dict, words allow, words ban)
      hClose h
      return out
  where
    getNeigh :: [String] -> Map.Map String Int
    getNeigh a = Map.fromList $ getNeigh' a []
    getNeigh' :: [String] -> [(String, Int)] -> [(String, Int)]
    getNeigh'        [] l = l
    getNeigh' (x:y:xs) [] = getNeigh' xs [(x, read y)]
    getNeigh' (x:y:xs)  l = getNeigh' xs (l ++ (x, read y) : [])
    ff :: Handle -> Word -> [(String, Word)] -> IO [(String, Word)]
    ff h word nm = do
      l <- hGetLine h
      let wl = words l
      let l1 = length $ filter (\x -> x /= ' ') l
      let l2 = length wl
      let l3 = elem ':' l
      let l4 = if l1 > 3 && l2 > 0 && l3 == True then True else False
      let ll = if l4 == True then tail wl else ["BAD BAD BAD"]
      let ww = if l4 == True then case (head wl) of
                           "word:"    -> (Word (unwords ll) 0 Map.empty Map.empty [] UnknownEPos)
                           "name:"    -> (Name (unwords ll) 0 Map.empty Map.empty [])
                           -- "place:"   -> word{place=(unwords ll)}
                           -- "phrase:"  -> word{phrase=(unwords ll)}
                           "count:"   -> word{count=(read $ unwords $ ll)}
                           "before:"  -> word{FuglyLib.before=(getNeigh $ ll)}
                           "after:"   -> word{FuglyLib.after=(getNeigh $ ll)}
                           "related:" -> word{related=(joinWords '"' ll)}
                           "pos:"     -> word{FuglyLib.pos=(readEPOS $ unwords $ ll)}
                           "end:"     -> word
                           _          -> word
               else word
      if l4 == False then do putStrLn ("Oops: " ++ l) >> return nm
        else if (head wl) == "end:" then
               ff h ww (nm ++ ((wordGetWord ww), ww) : [])
             else if (head wl) == ">END<" then
                    return nm
                  else
                    ff h ww nm

qWords = ["if", "is", "are", "do", "why", "what", "when", "who", "where", "want", "am", "can", "will"]
badEndWords = ["a", "the", "I", "I've", "I'll", "I'm", "I'd", "i", "and", "are", "an", "your", "you're", "you", "who", "with", "was",
               "to", "in", "is", "as", "if", "do", "so", "am", "of", "for", "or", "he", "she", "they", "they're", "we", "it", "it's",
               "its", "from", "go", "my", "that", "that's", "whose", "when", "what", "has", "had", "make", "makes", "person's", "but",
               "our", "their", "than", "at", "on", "into", "just", "by", "he's", "she's"]

wordIs         (Word w c b a r p) = "word"
wordIs         (Name n c b a r)   = "name"
wordIs         (Place p c b a r)  = "place"
wordIs         (Phrase p c b a r) = "phrase"
wordGetWord    (Word w c b a r p) = w
wordGetWord    (Name n c b a r)   = n
wordGetWord    _                  = []
wordGetCount   (Word w c b a r p) = c
wordGetCount   (Name n c b a r)   = c
wordGetCount   _                  = 0
wordGetAfter   (Word w c b a r p) = a
wordGetAfter   (Name n c b a r)   = a
wordGetAfter   _                  = Map.empty
wordGetBefore  (Word w c b a r p) = b
wordGetBefore  (Name n c b a r)   = b
wordGetBefore  _                  = Map.empty
wordGetRelated (Word w c b a r p) = r
wordGetRelated (Name n c b a r)   = r
wordGetRelated _                  = []
wordGetPos     (Word w c b a r p) = p
wordGetPos     (Name n c b a r)   = UnknownEPos
wordGetPos     _                  = UnknownEPos
wordGetwc      (Word w c _ _ _ _) = (c, w)
wordGetwc      (Name w c _ _ _)   = (c, w)

insertWords :: Fugly -> [String] -> IO (Map.Map String Word)
insertWords (Fugly {dict=d}) [] = return d
insertWords fugly [x] = insertWord fugly x [] [] []
insertWords fugly@(Fugly dict pgf _ _ _ _) msg@(x:y:xs) =
  case (len) of
    2 -> do ff <- insertWord fugly x [] y []
            insertWord fugly{dict=ff} y x [] []
    _ -> insertWords' fugly 0 len msg
  where
    len = length msg
    insertWords' (Fugly {dict=d}) _ _ [] = return d
    insertWords' f@(Fugly {dict=d}) i l msg
      | i == 0     = do ff <- insertWord f (msg!!i) [] (msg!!(i+1)) []
                        insertWords' f{dict=ff} (i+1) l msg
      | i > l - 1  = return d
      | i == l - 1 = do ff <- insertWord f (msg!!i) (msg!!(i-1)) [] []
                        insertWords' f{dict=ff} (i+1) l msg
      | otherwise  = do ff <- insertWord f (msg!!i) (msg!!(i-1)) (msg!!(i+1)) []
                        insertWords' f{dict=ff} (i+1) l msg

insertWord :: Fugly -> String -> String -> String -> String -> IO (Map.Map String Word)
insertWord fugly@(Fugly dict pgf wne aspell allow ban) [] _ _ _ = return dict
insertWord fugly@(Fugly dict pgf wne aspell allow ban) word before after pos = do
    n <- asIsName aspell word
    let out = if elem word ban || elem before ban || elem after ban then return dict
              else if isJust w then f $ fromJust w
                   else if n then insertName' fugly w (toUpperWord $ cleanString word) bi ai
                        else if isJust ww then insertWordRaw' fugly ww (map toLower $ cleanString word) bi ai pos
                             else insertWordRaw' fugly w (map toLower $ cleanString word) bi ai pos
    out
  where
    w = Map.lookup word dict
    ww = Map.lookup (map toLower $ cleanString word) dict
    a = Map.lookup after dict
    b = Map.lookup before dict
    ai = if isJust a then after else map toLower $ cleanString after
    bi = if isJust b then before else map toLower $ cleanString before
    f (Word {})  = insertWordRaw' fugly w word bi ai pos
    f (Name {})  = insertName'    fugly w word bi ai

insertWordRaw f@(Fugly {dict=d}) w b a p = insertWordRaw' f (Map.lookup w d) w b a p
insertWordRaw' :: Fugly -> Maybe Word -> String -> String
                 -> String -> String -> IO (Map.Map String Word)
insertWordRaw' (Fugly {dict=d}) _ [] _ _ _ = return d
insertWordRaw' (Fugly dict _ wne aspell allow _) w word before after pos = do
  pp <- (if null pos then wnPartPOS wne word else return $ readEPOS pos)
  pa <- wnPartPOS wne after
  pb <- wnPartPOS wne before
  rel <- wnRelated' wne word "Hypernym" pp
  let nn x y  = if elem x allow then x
                else if y == UnknownEPos && Aspell.check aspell (ByteString.pack x) == False then [] else x
  let i x = Map.insert x (Word x 1 (e (nn before pb)) (e (nn after pa)) rel pp) dict
  if isJust w then
    return $ Map.insert word (Word word c (nb before pb) (na after pa)
                            (wordGetRelated $ fromJust w)
                            (wordGetPos $ fromJust w)) dict
         else if elem word allow then
           return $ i word
           else if pp /= UnknownEPos || Aspell.check aspell (ByteString.pack word) then
                  return $ i word
                else
                  return dict
  where
    e [] = Map.empty
    e x = Map.singleton x 1
    c = incCount' (fromJust w) 1
    na x y = if elem x allow then incAfter' (fromJust w) x 1
                else if y /= UnknownEPos || Aspell.check aspell (ByteString.pack x) then incAfter' (fromJust w) x 1
                     else wordGetAfter (fromJust w)
    nb x y = if elem x allow then incBefore' (fromJust w) x 1
                else if y /= UnknownEPos || Aspell.check aspell (ByteString.pack x) then incBefore' (fromJust w) x 1
                     else wordGetBefore (fromJust w)

insertName f@(Fugly {dict=d}) w b a = insertName' f (Map.lookup w d) w b a
insertName' :: Fugly -> Maybe Word -> String -> String
              -> String -> IO (Map.Map String Word)
insertName' (Fugly dict _ wne aspell _ _) _ [] _ _ = return dict
insertName' (Fugly dict _ wne aspell allow _) w name before after = do
  pa <- wnPartPOS wne after
  pb <- wnPartPOS wne before
  rel <- wnRelated' wne name "Hypernym" (POS Noun)
  if isJust w then
    return $ Map.insert name (Name name c (nb before pb) (na after pa)
                              (wordGetRelated (fromJust w))) dict
    else
    return $ Map.insert name (Name name 1 (e (nn before pb)) (e (nn after pa)) rel) dict
  where
    e [] = Map.empty
    e x = Map.singleton x 1
    c = incCount' (fromJust w) 1
    na x y = if elem x allow then incAfter' (fromJust w) x 1
                else if y /= UnknownEPos || Aspell.check aspell (ByteString.pack x) then incAfter' (fromJust w) x 1
                     else wordGetAfter (fromJust w)
    nb x y = if elem x allow then incBefore' (fromJust w) x 1
                else if y /= UnknownEPos || Aspell.check aspell (ByteString.pack x) then incBefore' (fromJust w) x 1
                     else wordGetBefore (fromJust w)
    nn x y  = if elem x allow then x
                else if y == UnknownEPos && Aspell.check aspell (ByteString.pack x) == False then [] else x

dropWord :: Map.Map String Word -> String -> Map.Map String Word
dropWord m word = Map.map del' (Map.delete word m)
    where
      del' (Word w c b a r p) = (Word w c (Map.delete word b) (Map.delete word a) r p)
      del' (Name w c b a r) = (Name w c (Map.delete word b) (Map.delete word a) r)

ageWord :: Map.Map String Word -> String -> Map.Map String Word
ageWord m word = Map.map age m
    where
      age ww@(Word w c b a r p) = (Word w (if w == word then if c - 1 < 0 then 0 else c - 1 else c)
                                   (incBefore' ww word (-1)) (incAfter' ww word (-1)) r p)
      age ww@(Name w c b a r)   = (Name w (if w == word then if c - 1 < 0 then 0 else c - 1 else c)
                                   (incBefore' ww word (-1)) (incAfter' ww word (-1)) r)

ageWords :: Map.Map String Word -> Map.Map String Word
ageWords m = cleanWords $ f m (listWords m)
    where
      f m []     = m
      f m (x:xs) = f (ageWord m x) xs

cleanWords :: Map.Map String Word -> Map.Map String Word
cleanWords = Map.filter (\x -> wordGetCount x > 0)

incCount' :: Word -> Int -> Int
incCount' (Word _ c _ _ _ _) n = if c + n < 0 then 0 else c + n
incCount' (Name _ c _ _ _)   n = if c + n < 0 then 0 else c + n

incBefore' :: Word -> String -> Int -> Map.Map String Int
incBefore' (Word _ _ b _ _ _) []     n = b
incBefore' (Word _ _ b _ _ _) before n =
  if isJust w then
    if (fromJust w) + n < 1 then Map.delete before b
    else Map.insert before ((fromJust w) + n) b
  else if n < 0 then b
       else Map.insert before n b
  where
    w = Map.lookup before b
incBefore' (Name _ _ b _ _)   []   n = b
incBefore' (Name w c b a r) before n = incBefore' (Word w c b a r (POS Noun)) before n

-- incBefore :: Map.Map String Word -> String -> String -> Map.Map String Int
-- incBefore m word before = do
--   let w = Map.lookup word m
--   if isJust w then incBefore' (fromJust w) before
--     else Map.empty

incAfter' :: Word -> String -> Int -> Map.Map String Int
incAfter' (Word _ _ _ a _ _) []     n = a
incAfter' (Word _ _ _ a _ _) after  n =
  if isJust w then
    if (fromJust w) + n < 1 then Map.delete after a
    else Map.insert after ((fromJust w) + n) a
  else if n < 0 then a
       else Map.insert after n a
  where
    w = Map.lookup after a
incAfter' (Name _ _ _ a _)   []  n = a
incAfter' (Name w c b a r) after n = incAfter' (Word w c b a r (POS Noun)) after n

-- incAfter :: Map.Map String Word -> String -> String -> Map.Map String Int
-- incAfter m word after = do
--   let w = Map.lookup word m
--   if isJust w then incAfter' (fromJust w) after
--     else Map.empty

listNeigh :: Map.Map String Int -> [String]
listNeigh m = [w | (w, c) <- Map.toList m]

listNeigh2 :: Map.Map String Int -> [String]
listNeigh2 m = concat [[w, show c] | (w, c) <- Map.toList m]

listNeighMax :: Map.Map String Int -> [String]
listNeighMax m = [w | (w, c) <- Map.toList m, c == maximum [c | (w, c) <- Map.toList m]]

-- listNeighMax2 :: Map.Map String Int -> [String]
-- listNeighMax2 m = concat [[w, show c] | (w, c) <- Map.toList m,
--                           c == maximum [c | (w, c) <- Map.toList m]]

listNeighLeast :: Map.Map String Int -> [String]
listNeighLeast m = [w | (w, c) <- Map.toList m, c == minimum [c | (w, c) <- Map.toList m]]

listWords :: Map.Map String Word -> [String]
listWords m = map wordGetWord $ Map.elems m

listWordsCountSort :: Map.Map String Word -> [String]
listWordsCountSort m = reverse $ map snd (sort $ map wordGetwc $ Map.elems m)

listWordsCountSort2 :: Map.Map String Word -> Int -> [String]
listWordsCountSort2 m num = concat [[w, show c, ";"] | (c, w) <- take num $ reverse $
                            sort $ map wordGetwc $ Map.elems m]

listNamesCountSort2 :: Map.Map String Word -> Int -> [String]
listNamesCountSort2 m num = concat [[w, show c, ";"] | (c, w) <- take num $ reverse $
                            sort $ map wordGetwc $ filter (\x -> wordIs x == "name") $ Map.elems m]

listWordFull :: Map.Map String Word -> String -> String
listWordFull m word =
  if isJust ww then
    unwords $ f (fromJust ww)
  else
    "Nothing!"
  where
    ww = Map.lookup word m
    f (Word w c b a r p) = ["word:", w, "count:", show c, " before:",
                 unwords $ listNeigh2 b, " after:", unwords $ listNeigh2 a,
                 " pos:", (show p), " related:", unwords r]
    f (Name w c b a r) = ["name:", w, "count:", show c, " before:",
                 unwords $ listNeigh2 b, " after:", unwords $ listNeigh2 a,
                 " related:", unwords r]

cleanStringWhite :: (Char -> Bool) -> String -> String
cleanStringWhite _ [] = []
cleanStringWhite f (x:xs)
        | not $ f x =     cleanStringWhite f xs
        | otherwise = x : cleanStringWhite f xs

cleanStringBlack :: (Char -> Bool) -> String -> String
cleanStringBlack _ [] = []
cleanStringBlack f (x:xs)
        | f x       =     cleanStringBlack f xs
        | otherwise = x : cleanStringBlack f xs

cleanString :: String -> String
cleanString [] = []
cleanString "i" = "I"
cleanString x
    | length x > 1 = filter (\x -> isAlpha x || x == '\'' || x == '-' || x == ' ') x
    | x == "I" || map toLower x == "a" = x
    | otherwise = []

dePlenk :: String -> String
dePlenk []  = []
dePlenk s   = dePlenk' s []
  where
    dePlenk' [] l  = l
    dePlenk' [x] l = l ++ x:[]
    dePlenk' a@(x:xs) l
      | length a == 1                             = l ++ x:[]
      | x == ' ' && (h == ' ' || isPunctuation h) = dePlenk' (fTail "dePlenk" [] xs) (l ++ h:[])
      | otherwise                                 = dePlenk' xs (l ++ x:[])
      where
        h = fHead "dePlenk" '!' xs

strip :: Eq a => a -> [a] -> [a]
strip _ [] = []
strip a (x:xs)
    | x == a    = strip a xs
    | otherwise = x : strip a xs

replace :: Eq a => a -> a -> [a] -> [a]
replace _ _ [] = []
replace a b (x:xs)
    | x == a    = b : replace a b xs
    | otherwise = x : replace a b xs

joinWords :: Char -> [String] -> [String]
joinWords _ [] = []
joinWords a s = joinWords' a $ filter (not . null) s
  where
    joinWords' _ [] = []
    joinWords' a (x:xs)
      | (fHead "joinWords" ' ' x) == a = unwords (x : (take num xs)) : joinWords a (drop num xs)
      | otherwise                      = x : joinWords a xs
      where
        num = (fromMaybe 0 (elemIndex a $ map (\x -> fLast "joinWords" '!' x) xs)) + 1

fixUnderscore :: String -> String
fixUnderscore = strip '"' . replace ' ' '_'

toUpperWord :: String -> String
toUpperWord [] = []
toUpperWord w = (toUpper $ head w) : tail w

toUpperSentence :: [String] -> [String]
toUpperSentence []     = []
toUpperSentence [x]    = [toUpperWord x]
toUpperSentence (x:xs) = toUpperWord x : xs

endSentence :: [String] -> [String]
endSentence []  = []
endSentence msg = (init msg) ++ ((fLast "endSentence" [] msg) ++ if elem (head msg) qWords then "?" else ".") : []

fHead a b [] = unsafePerformIO (do putStrLn ("fHead: error in " ++ a) ; return b)
fHead a b c  = head c
fLast a b [] = unsafePerformIO (do putStrLn ("fLast: error in " ++ a) ; return b)
fLast a b c  = last c
fTail a b [] = unsafePerformIO (do putStrLn ("fTail: error in " ++ a) ; return b)
fTail a b c  = tail c

wnPartString :: WordNetEnv -> String -> IO String
wnPartString _ [] = return "Unknown"
wnPartString w a  = do
    ind1 <- indexLookup w a Noun
    ind2 <- indexLookup w a Verb
    ind3 <- indexLookup w a Adj
    ind4 <- indexLookup w a Adv
    return (type' ((count' ind1) : (count' ind2) : (count' ind3) : (count' ind4) : []))
  where
    count' a = if isJust a then senseCount (fromJust a) else 0
    type' [] = "Other"
    type' a
      | a == [0, 0, 0, 0]                             = "Unknown"
      | fromMaybe (-1) (elemIndex (maximum a) a) == 0 = "Noun"
      | fromMaybe (-1) (elemIndex (maximum a) a) == 1 = "Verb"
      | fromMaybe (-1) (elemIndex (maximum a) a) == 2 = "Adj"
      | fromMaybe (-1) (elemIndex (maximum a) a) == 3 = "Adv"
      | otherwise                                     = "Unknown"

wnPartPOS :: WordNetEnv -> String -> IO EPOS
wnPartPOS _ [] = return UnknownEPos
wnPartPOS w a  = do
    ind1 <- indexLookup w a Noun
    ind2 <- indexLookup w a Verb
    ind3 <- indexLookup w a Adj
    ind4 <- indexLookup w a Adv
    return (type' ((count' ind1) : (count' ind2) : (count' ind3) : (count' ind4) : []))
  where
    count' a = if isJust a then senseCount (fromJust a) else 0
    type' [] = UnknownEPos
    type' a
      | a == [0, 0, 0, 0]                             = UnknownEPos
      | fromMaybe (-1) (elemIndex (maximum a) a) == 0 = POS Noun
      | fromMaybe (-1) (elemIndex (maximum a) a) == 1 = POS Verb
      | fromMaybe (-1) (elemIndex (maximum a) a) == 2 = POS Adj
      | fromMaybe (-1) (elemIndex (maximum a) a) == 3 = POS Adv
      | otherwise                                     = UnknownEPos

wnGloss :: WordNetEnv -> String -> String -> IO String
wnGloss _ [] _ = return "Nothing!  Error!  Abort!"
wnGloss wne word [] = do
    wnPos <- wnPartString wne (fixUnderscore word)
    wnGloss wne word wnPos
wnGloss wne word pos = do
    let wnPos = fromEPOS $ readEPOS pos
    let result = map (getGloss . getSynset) (runs wne (search
                     (fixUnderscore word) wnPos AllSenses))
    if (null result) then return "Nothing!" else
      return $ unwords result

wnRelated :: WordNetEnv -> String -> String -> String -> IO String
wnRelated wne c d pos = do
    x <- wnRelated' wne c d $ readEPOS pos
    f (filter (not . null) x) []
  where
    f []     a = return a
    f (x:xs) a = f xs (x ++ " " ++ a)
wnRelated' :: WordNetEnv -> String -> String -> EPOS -> IO [String]
wnRelated' wne [] _ _  = return [[]] :: IO [String]
wnRelated' wne c [] pos  = wnRelated' wne c "Hypernym" pos
wnRelated' wne c d pos = do
    let wnForm = readForm d
    let result = if (map toLower d) == "all" then concat $ map (fromMaybe [[]])
                    (runs wne (relatedByListAllForms (search (fixUnderscore c)
                     (fromEPOS pos) AllSenses)))
                 else fromMaybe [[]] (runs wne (relatedByList wnForm (search
                      (fixUnderscore c) (fromEPOS pos) AllSenses)))
    if (null result) || (null $ concat result) then return [] else
      return $ map (\x -> replace '_' ' ' $ unwords $ map (++ "\"") $
                    map ('"' :) $ concat $ map (getWords . getSynset) x) result

wnClosure :: WordNetEnv -> String -> String -> String -> IO String
wnClosure _ [] _ _         = return []
wnClosure wne word [] _    = wnClosure wne word "Hypernym" []
wnClosure wne word form [] = do
    wnPos <- wnPartString wne (fixUnderscore word)
    wnClosure wne word form wnPos
wnClosure wne word form pos = do
    let wnForm = readForm form
    let wnPos = fromEPOS $ readEPOS pos
    let result = runs wne (closureOnList wnForm
                           (search (fixUnderscore word) wnPos AllSenses))
    if (null result) then return [] else
      return $ unwords $ map (\x -> if isNothing x then return '?'
                                    else (replace '_' ' ' $ unwords $ map (++ "\"") $
                                          map ('"' :) $ nub $ concat $ map
                                          (getWords . getSynset)
                                          (flatten (fromJust x)))) result

wnMeet :: WordNetEnv -> String -> String -> String -> IO String
wnMeet _ [] _ _ = return []
wnMeet _ _ [] _ = return []
wnMeet w c d [] = do
    wnPos <- wnPartString w (fixUnderscore c)
    wnMeet w c d wnPos
wnMeet w c d e  = do
    let wnPos = fromEPOS $ readEPOS e
    let r1 = runs w (search (fixUnderscore c) wnPos 1)
    let r2 = runs w (search (fixUnderscore d) wnPos 1)
    if not (null r1) && not (null r2) then do
        let result = runs w (meet emptyQueue (head $ r1) (head $ r2))
        if isNothing result then return [] else
            return $ replace '_' ' ' $ unwords $ map (++ "\"") $ map ('"' :) $
                    getWords $ getSynset $ fromJust result
        else return []

wnIsName :: WordNetEnv -> String -> IO Bool
wnIsName _ [] = return False
wnIsName wne word = do
    pos <- wnPartString wne word
    w <- wnGloss wne word pos
    putStrLn w
    if pos == "Noun" && w =~ toUpperWord word && length word > 1 then return True else return False

asIsName :: Aspell.SpellChecker -> String -> IO Bool
asIsName _ [] = return False
asIsName aspell word = do
    let l = map toLower word
    let w = toUpperWord l
    n1 <- asSuggest aspell l
    n2 <- asSuggest aspell w
    let nn1 = if null n1 then False else (head $ words n1) == l
    let nn2 = if null n2 then False else (head $ words n2) == w
    return (if nn1 == False && nn2 == True then True else False)

-- LD_PRELOAD=/usr/lib64/libjemalloc.so.1
asSuggest :: Aspell.SpellChecker -> String -> IO String
asSuggest _ [] = return []
asSuggest aspell word = runInBoundThread (do w <- Aspell.suggest aspell (ByteString.pack word)
                                             return $ unwords $ map ByteString.unpack w)

{--
gfRandom :: Fugly -> Int -> Int -> IO String
gfRandom fugly lim num = do r <- gfRandom' fugly lim
                            return $ unwords $ toUpperSentence $ endSentence $ words $ cleanStringBlack isDigit $
                              cleanStringBlack isPunctuation $ unwords $ take num r
  where
    gfRandom' :: Fugly -> Int -> IO [String]
    gfRandom' (Fugly {pgf=p}) lim = do
      r <- Random.newStdGen
      let rr = generateRandomDepth r p (startCat p) (Just lim)
      return (if null rr then [] else words $ linearize p (head $ languages p) (head rr))

gfAll :: PGF -> Int -> String
gfAll pgf num = unwords $ toUpperSentence $ endSentence $ take 15 $ words $ linearize pgf (head $ languages pgf) ((generateAllDepth pgf (startCat pgf) (Just 3))!!num)

gfTranslate :: PGF -> String -> String
gfTranslate pgf s = case parseAllLang pgf (startCat pgf) s of
    (lg,t:_):_ -> unlines [linearize pgf l t | l <- languages pgf, l /= lg]
    _          -> "Me no understand Engrish."
--}

gfParseBool :: PGF -> Int -> String -> Bool
gfParseBool _ _ [] = False
gfParseBool pgf len msg
  | elem (last w) badEndWords = False
  | length w > len = (gfParseBoolA pgf $ take len w) && (gfParseBool pgf len (unwords $ drop len w))
  | otherwise      = gfParseBoolA pgf w
    where
      w = words msg

gfParseBoolA :: PGF -> [String] -> Bool
gfParseBoolA pgf msg
  | null msg                                 = False
  | null $ parse pgf lang (startCat pgf) m   = False
  | otherwise                                = True
  where
    m = unwords msg
    lang = head $ languages pgf

{--
gfParseBool2 :: PGF -> String -> Bool
gfParseBool2 pgf msg = lin pgf lang (parse_ pgf lang (startCat pgf) Nothing msg)
  where
    lin pgf lang (ParseOk tl, _)      = True
    lin pgf lang _                    = False
    lang = head $ languages pgf
--}

gfParseC :: PGF -> String -> [String]
gfParseC pgf msg = lin pgf lang (parse_ pgf lang (startCat pgf) Nothing msg)
  where
    lin pgf lang (ParseOk tl, b)      = map (lin' pgf lang) tl
    lin pgf lang (ParseFailed a, b)   = ["parse failed at " ++ show a ++
                                        " tokens: " ++ showBracketedString b]
    lin pgf lang (ParseIncomplete, b) = ["parse incomplete: " ++ showBracketedString b]
    lin pgf lang _                    = ["No parse!"]
    lin' pgf lang t = "parse: " ++ showBracketedString (bracketedLinearize pgf lang t)
    lang = head $ languages pgf

gfCategories :: PGF -> [String]
gfCategories pgf = map showCId (categories pgf)

sentence :: Fugly -> Int -> Int -> Int -> Int -> [String] -> [IO String]
sentence _ _ _ _ _ [] = [return []] :: [IO String]
sentence fugly@(Fugly dict pgf wne aspell _ ban) randoms stries slen plen msg = do
  let s1f x = if null x then return []
              else if gfParseBool pgf plen (unwords x) && length x > 2 then return x else return []
  let s1a x = do
      z <- findNextWord fugly 0 randoms True x
      let zz = if null z then [] else head z
      y <- findNextWord fugly 1 randoms True zz
      let yy = if null y then [] else head y
      let c = if null zz && null yy then 2 else if null zz || null yy then 3 else 4
      w <- s1b fugly slen c $ findNextWord fugly 1 randoms False x
      ww <- wnReplaceWords fugly randoms w
      s1f $ filter (not . null) ([yy] ++ [zz] ++ [x] ++ (filter (\y -> length y > 0 && not (elem y ban)) ww))
  let s1d x = do
      w <- x
      if null w then return []
        else return ((init w) ++ ((fLast "sentence: s1d" [] w) ++
                                  if elem (map toLower $ head w) qWords then "?" else ".") : [])
  let s1e x = do
      w <- x
      if null w then return []
        else return ((s1c w : [] ) ++ fTail "sentence: s1e" [] w)
  take stries $ map (\x -> do y <- x ; return $ dePlenk $ unwords y) (map (s1e . s1d . s1a) (cycle msg))
  where
    s1b :: Fugly -> Int -> Int -> IO [String] -> IO [String]
    s1b f@(Fugly d p w s a b) n i msg = do
      ww <- msg
      if null ww then return []
        else if i >= n then return $ nub ww else do
               www <- findNextWord f i randoms False (fLast "sentence: s1b" [] ww)
               s1b f n (i + 1) (return $ ww ++ www)
    s1c :: [String] -> String
    s1c [] = []
    s1c w = ((toUpper $ head $ head w) : []) ++ (fTail "sentence: s1c" [] $ head w)

chooseWord :: WordNetEnv -> [String] -> IO [String]
chooseWord _ [] = return []
chooseWord wne msg = do
  cc <- c1 msg []
  if null cc then return msg else c1 msg []
  where
    c1 [] m = return $ reverse m
    c1 msg@(x:xs) m = do
      p <- wnPartPOS wne x
      if p /= UnknownEPos then c1 xs (m ++ [x])
        else c1 xs m

wnReplaceWords :: Fugly -> Int -> [String] -> IO [String]
wnReplaceWords _ _ [] = return []
wnReplaceWords fugly@(Fugly dict pgf wne aspell _ _) randoms msg = do
  cw <- chooseWord wne msg
  cr <- Random.getStdRandom (Random.randomR (0, (length cw) - 1))
  rr <- Random.getStdRandom (Random.randomR (0, 99))
  w <- if not $ null cw then findRelated wne (cw!!cr) else return []
  let out = filter (not . null) ((takeWhile (/= (cw!!cr)) msg) ++ [w] ++ (tail $ dropWhile (/= (cw!!cr)) msg))
  if rr + randoms < 90 then
    return out
    else if randoms < 90 then
      wnReplaceWords fugly randoms out
      else sequence $ map (\x -> findRelated wne x) msg

asReplaceWords :: Fugly -> [String] -> IO [String]
asReplaceWords _ [] = return [[]]
asReplaceWords fugly msg = do
  sequence $ map (\x -> asReplace fugly x) msg

asReplace :: Fugly -> String -> IO String
asReplace _ [] = return []
asReplace fugly@(Fugly dict _ wne aspell _ _) word =
  if (elem ' ' word) || (elem '\'' word) || (head word == (toUpper $ head word)) then return word
    else do
    a  <- asSuggest aspell word
    p <- wnPartPOS wne word
    let w = Map.lookup word dict
    let rw = words a
    rr <- Random.getStdRandom (Random.randomR (0, (length rw) - 1))
    if null rw || p /= UnknownEPos || isJust w then return word else
      if head rw == word then return word else return (rw!!rr)

findNextWord :: Fugly -> Int -> Int -> Bool -> String -> IO [String]
findNextWord _ _ _ _ [] = return []
findNextWord fugly@(Fugly dict pgf wne aspell _ _) i randoms prev word = do
  let ln = if isJust w then length neigh else 0
  let lm = if isJust w then length neighmax else 0
  let ll = if isJust w then length neighleast else 0
  nr <- Random.getStdRandom (Random.randomR (0, ln - 1))
  mr <- Random.getStdRandom (Random.randomR (0, lm - 1))
  lr <- Random.getStdRandom (Random.randomR (0, ll - 1))
  rr <- Random.getStdRandom (Random.randomR (0, 99))
  let f1 = if isJust w && length neigh > 0 then neighleast!!lr else []
  let f2 = if isJust w && length neigh > 0 then case mod i 3 of
        0 -> neigh!!nr
        1 -> neighleast!!lr
        2 -> neighleast!!lr
        _ -> []
           else []
  let f3 = if isJust w && length neigh > 0 then case mod i 5 of
        0 -> neighleast!!lr
        1 -> neigh!!nr
        2 -> neighmax!!mr
        3 -> neigh!!nr
        4 -> neigh!!nr
        _ -> []
           else []
  let f4 = if isJust w && length neigh > 0 then case mod i 3 of
        0 -> neighmax!!mr
        1 -> neigh!!nr
        2 -> neighmax!!mr
        _ -> []
           else []
  let f5 = if isJust w && length neigh > 0 then neighmax!!mr else []
  if randoms > 89 then return $ replace "i" "I" $ words f1 else
    if rr < randoms - 25 then return $ replace "i" "I" $ words f2 else
      if rr < randoms + 35 then return $ replace "i" "I" $ words f3 else
        if rr < randoms + 65 then return $ replace "i" "I" $ words f4 else
          return $ replace "i" "I" $ words f5
    where
      w          = Map.lookup word dict
      wordGet'   = if prev then wordGetBefore else wordGetAfter
      neigh      = listNeigh $ wordGet' (fromJust w)
      neighmax   = listNeighMax $ wordGet' (fromJust w)
      neighleast = listNeighLeast $ wordGet' (fromJust w)

findRelated :: WordNetEnv -> String -> IO String
findRelated wne word = do
  pp <- wnPartPOS wne word
  if pp /= UnknownEPos then do
    hyper <- wnRelated' wne word "Hypernym" pp
    hypo  <- wnRelated' wne word "Hyponym" pp
    anto  <- wnRelated' wne word "Antonym" pp
    let hyper' = filter (\x -> not $ elem ' ' x && length x > 2) $ map (strip '"') hyper
    let hypo'  = filter (\x -> not $ elem ' ' x && length x > 2) $ map (strip '"') hypo
    let anto'  = filter (\x -> not $ elem ' ' x && length x > 2) $ map (strip '"') anto
    if null anto' then
      if null hypo' then
        if null hyper' then
          return word
          else do
            r <- Random.getStdRandom (Random.randomR (0, (length hyper') - 1))
            return (hyper'!!r)
        else do
          r <- Random.getStdRandom (Random.randomR (0, (length hypo') - 1))
          return (hypo'!!r)
      else do
        r <- Random.getStdRandom (Random.randomR (0, (length anto') - 1))
        return (anto'!!r)
    else return word

dictLookup :: Fugly -> String -> String -> IO String
dictLookup fugly@(Fugly _ _ wne aspell _ _) word pos = do
    gloss <- wnGloss wne word pos
    if gloss == "Nothing!" then
       do a <- asSuggest aspell word
          return (gloss ++ " Perhaps you meant: " ++
                  (unwords (filter (\x -> x /= word) (words a))))
      else return gloss
