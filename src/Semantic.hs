{-# LANGUAGE GADTs #-}
module Semantic
( parseAndRenderBlob
, parseDiffAndRenderBlobPair
, diffAndRenderTermPair
) where

import Data.Functor.Both as Both
import Data.Record
import Diff
import Info
import Interpreter
import qualified Language
import Patch
import Parser
import Prologue
import Renderer
import Semantic.Task as Task
import Source
import Term

-- This is the primary interface to the Semantic library which provides two
-- major classes of functionality: semantic parsing and diffing of source code
-- blobs.
--
-- Design goals:
--   - No knowledge of the filesystem or Git.
--   - Built in concurrency where appropriate.
--   - Easy to consume this interface from other application (e.g a cmdline or web server app).

-- | A task to parse a 'SourceBlob' and render the resulting 'Term'.
parseAndRenderBlob :: TermRenderer output -> SourceBlob -> Task output
parseAndRenderBlob renderer blob@SourceBlob{..} = case renderer of
  JSONTermRenderer -> case blobLanguage of
    Just Language.Python -> parse pythonParser source >>= render (renderJSON (Identity blob))
    language -> parse (parserForLanguage language) source >>= decorate identifierAlgebra >>= render (renderJSON (Identity blob))
  SExpressionTermRenderer -> case blobLanguage of
    Just Language.Python -> parse pythonParser source >>= render renderSExpressionTerm . fmap (Info.Other "Term" :.)
    language -> parse (parserForLanguage language) source >>= render renderSExpressionTerm


-- | A task to parse a pair of 'SourceBlob's, diff them, and render the 'Diff'.
parseDiffAndRenderBlobPair :: Monoid output => DiffRenderer output -> Both SourceBlob -> Task output
parseDiffAndRenderBlobPair renderer blobs = case renderer of
  ToCDiffRenderer -> do
    terms <- distributeFor blobs $ \ blob -> do
      term <- parseSource blob
      decorate (declarationAlgebra (source blob)) term
    diffAndRenderTermPair blobs (runBothWith diffTerms) (uncurry renderToC) terms
  JSONDiffRenderer -> do
    terms <- distributeFor blobs (decorate identifierAlgebra <=< parseSource)
    diffAndRenderTermPair blobs (runBothWith diffTerms) (uncurry renderJSON) terms
  PatchDiffRenderer -> distributeFor blobs parseSource >>= diffAndRenderTermPair blobs (runBothWith diffTerms) (uncurry renderPatch)
  SExpressionDiffRenderer -> distributeFor blobs parseSource >>= diffAndRenderTermPair blobs (runBothWith diffTerms) (renderSExpressionDiff . Prologue.snd)
  where languages = blobLanguage <$> blobs
        parseSource = parse (if runBothWith (==) languages then parserForLanguage (Both.fst languages) else LineByLineParser) . source

-- | A task to diff a pair of 'Term's and render the 'Diff', producing insertion/deletion 'Patch'es for non-existent 'SourceBlob's.
diffAndRenderTermPair :: (Monoid output, Functor f) => Both SourceBlob -> Differ f a -> ((Both SourceBlob, Diff f a) -> output) -> Both (Term f a) -> Task output
diffAndRenderTermPair blobs differ renderer terms = case runJoin (nonExistentBlob <$> blobs) of
  (True, True) -> pure mempty
  (_, True) -> render renderer (blobs, deleting (Both.fst terms))
  (True, _) -> render renderer (blobs, inserting (Both.snd terms))
  _ -> diff differ terms >>= render renderer . (,) blobs
