{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Xsh.Interpretter (
    interpret
  ) where

import qualified Control.Concurrent.Async as Async

import qualified Data.Text as T
import qualified Data.Text.IO as T

import qualified System.Directory as Directory
import           System.Exit (ExitCode (..))
import           System.IO (IO, Handle)
import qualified System.Process as Process

import           Xsh.Data
import           Xsh.Prelude
import qualified Xsh.Expansion as Expansion

--
-- Given the handles for input, output and error, interpret this program.
--
interpret :: Handle -> Handle -> Handle -> Program -> IO ExitCode
interpret i o e program = do
  case program of
    Program [] ->
      pure ExitSuccess
    Program (x:[]) ->
      runList i o e x
    Program (x:xs) ->
      runList i o e x >> interpret i o e (Program xs)

--
-- BASELINE EXERCISE 17.
--
-- Given the handles for input, output and error, interpret this list.
--
runList :: Handle -> Handle -> Handle -> List -> IO ExitCode
runList i o e list =
  case list of
    SingletonList p ->
      runPipeline i o e p

    AndList l p -> do
      ec <- runList i o e l
      case ec of
        ExitSuccess ->
          runPipeline i o e p

        ExitFailure er ->
          pure $ ExitFailure er

    OrList l p -> do
      ec <- runList i o e l
      case ec of
        ExitSuccess ->
          pure ExitSuccess

        ExitFailure _er ->
          runPipeline i o e p

--
-- BASELINE EXERCISE 16.
--
-- Given the handles for input, output and error, interpret this pipeline.
--
-- The input should be fed to the first command in the pipeline, the
-- output of the first command should be fed to the input of the
-- second command and so on, the final commands output should go to
-- the provided output. Use the exit code of the final command.
--
-- Hint:
--   Proces.createPipe
--   Async.concurrently
--
runPipeline :: Handle -> Handle -> Handle -> Pipeline -> IO ExitCode
runPipeline i o e pipeline =
  case pipeline of
    SingletonPipeline c ->
      runCommand i o e c
    CompoundPipeline p c -> do
      (read, write) <- Process.createPipe
      (_ea, eb) <- Async.concurrently (runPipeline i write e p) (runCommand read o e c)
      pure eb

--
-- Execute the specified command.
--
runCommand :: Handle -> Handle -> Handle -> Command -> IO ExitCode
runCommand i o e command =
  case command of
    Command [] ->
      pure ExitSuccess
    Command [Word [UnquotedPart [TextFragment "cd"]], Word [UnquotedPart [TextFragment dir]]] -> do
      path <- Directory.makeAbsolute $ T.unpack dir
      ex <- Directory.doesDirectoryExist path
      case ex of
        True -> do
          Directory.setCurrentDirectory path
          pure ExitSuccess
        False -> do
          T.hPutStr e "What are you doing."
          T.hPutStr o "\n"
          pure $ ExitFailure 1


    Command (a:as) -> do
      -- NOTE: expand semantics assume a 1-1 atom mapping, this is a simplification
      --       it matches zsh non ${=...} expansion, but does not match normal POSIX.
      --       This is saner but possibly confusing, should do something nicer.
      (_, _, _, h) <- Process.createProcess (Process.proc (T.unpack . Expansion.expand $ a) (fmap (T.unpack . Expansion.expand) $ as)) {
          Process.std_in = Process.UseHandle i
        , Process.std_out = Process.UseHandle o
        , Process.std_err = Process.UseHandle e
        -- NOTE: this is critical, the forked process will have a reference to the
        --       pipe and it would never otherwise be closed in the child. This means
        --       the final process in the pipeline would hang forever waiting for the
        --       EOF on the pipe. If you choose to re-implement your own fork-exec,
        --       be aware of this.
        , Process.close_fds = True
        }
      Process.waitForProcess h
