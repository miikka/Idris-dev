{-# LANGUAGE PatternGuards #-}

module Core.Unify(unify, Fails) where

import Core.TT
import Core.Evaluate

import Control.Monad
import Control.Monad.State
import Debug.Trace

-- Unification is applied inside the theorem prover. We're looking for holes
-- which can be filled in, by matching one term's normal form against another.
-- Returns a list of hole names paired with the term which solves them, and
-- a list of things which need to be injective.

-- terms which need to be injective, with the things we're trying to unify
-- at the time

type Injs = [(TT Name, TT Name, TT Name)]
type Fails = [(TT Name, TT Name, Env, Err)]

data UInfo = UI Int Fails
     deriving Show

data UResult a = UOK a
               | UPartOK a
               | UFail Err

unify :: Context -> Env -> TT Name -> TT Name -> [Name] -> [Name] ->
         TC ([(Name, TT Name)], Fails)
unify ctxt env topx topy injtc holes =
--      trace ("Unifying " ++ show (topx, topy)) $
             -- don't bother if topx and topy are different at the head
      case runStateT (un False [] topx topy) (UI 0 []) of
        OK (v, UI _ []) -> return (filter notTrivial v, [])
        res -> 
               let topxn = normalise ctxt env topx
                   topyn = normalise ctxt env topy in
--                     trace ("Unifying " ++ show (topx, topy) ++ "\n\n==>\n" ++ show (topxn, topyn) ++ "\n\n" ++ show res ++ "\n\n") $
                     case runStateT (un False [] topxn topyn)
        	  	        (UI 0 []) of
                       OK (v, UI _ fails) -> 
                            return (filter notTrivial v, reverse fails)
--         Error e@(CantUnify False _ _ _ _ _)  -> tfail e
        	       Error e -> tfail e
  where
    notTrivial (x, P _ x' _) = x /= x'
    notTrivial _ = True

    headDiff (P (DCon _ _) x _) (P (DCon _ _) y _) = x /= y
    headDiff (P (TCon _ _) x _) (P (TCon _ _) y _) = x /= y
    headDiff _ _ = False

    injective (P (DCon _ _) _ _) = True
    injective (P (TCon _ _) _ _) = True
    injective (P _ n _)          = n `elem` injtc
    injective (App f a)          = injective f
    injective _                  = False

    notP (P _ _ _) = False
    notP _ = True

    sc i = do UI s f <- get
              put (UI (s+i) f)

    uplus u1 u2 = do UI s f <- get
                     r <- u1
                     UI s f' <- get
                     if (length f == length f') 
                        then return r
                        else do put (UI s f); u2

    un :: Bool -> [(Name, Name)] -> TT Name -> TT Name ->
          StateT UInfo 
          TC [(Name, TT Name)]
    un = un'
--     un fn names x y 
--         = let (xf, _) = unApply x
--               (yf, _) = unApply y in
--               if headDiff xf yf then unifyFail x y else
--                   uplus (un' fn names x y)
--                         (un' fn names (hnf ctxt env x) (hnf ctxt env y))

    un' :: Bool -> [(Name, Name)] -> TT Name -> TT Name ->
           StateT UInfo 
           TC [(Name, TT Name)]
    un' fn names x y | x == y = return [] -- shortcut
    un' fn names topx@(P (DCon _ _) x _) topy@(P (DCon _ _) y _)
                | x /= y = unifyFail topx topy
    un' fn names topx@(P (TCon _ _) x _) topy@(P (TCon _ _) y _)
                | x /= y = unifyFail topx topy
    un' fn names topx@(P (DCon _ _) x _) topy@(P (TCon _ _) y _)
                = unifyFail topx topy
    un' fn names topx@(P (TCon _ _) x _) topy@(P (DCon _ _) y _)
                = unifyFail topx topy
    un' fn bnames tx@(P _ x _) ty@(P _ y _)  
        | (x,y) `elem` bnames || x == y = do sc 1; return []
        | injective tx && not (holeIn env y || y `elem` holes)
             = unifyFail tx ty
        | injective ty && not (holeIn env x || x `elem` holes)
             = unifyFail tx ty
    un' fn bnames xtm@(P _ x _) tm
        | holeIn env x || x `elem` holes
                       = do UI s f <- get
                            -- injectivity check
                            if (notP tm && fn) 
--                               trace (show (x, tm, normalise ctxt env tm)) $
--                                 put (UI s ((tm, topx, topy) : i) f)
                                 then unifyTmpFail xtm tm 
                                 else do sc 1
                                         checkCycle (x, tm)
        | not (injective xtm) && injective tm = unifyFail xtm tm
    un' fn bnames tm ytm@(P _ y _)
        | holeIn env y || y `elem` holes
                       = do UI s f <- get
                            -- injectivity check
                            if (notP tm && fn)
--                               trace (show (y, tm, normalise ctxt env tm)) $
--                                 put (UI s ((tm, topx, topy) : i) f)
                                 then unifyTmpFail tm ytm
                                 else do sc 1
                                         checkCycle (y, tm)
        | not (injective ytm) && injective tm = unifyFail ytm tm
    un' fn bnames (V i) (P _ x _)
        | fst (bnames!!i) == x || snd (bnames!!i) == x = do sc 1; return []
    un' fn bnames (P _ x _) (V i)
        | fst (bnames!!i) == x || snd (bnames!!i) == x = do sc 1; return []

    un' fn bnames appx@(App fx ax) appy@(App fy ay)
      |    injective fx && metavarApp appy 
        || injective fy && metavarApp appx 
        || injective fx && injective fy  
        || fx == fy
         = do let (headx, _) = unApply fx
              let (heady, _) = unApply fy
              -- fail quickly if the heads are disjoint
              checkHeads headx heady
--              if True then -- (injective fx || injective fy || fx == fy) then
--              if (injective fx && metavarApp appy) || 
--                 (injective fy && metavarApp appx) ||
--                 (injective fx && injective fy) || fx == fy
              uplus
                (do hf <- un' True bnames fx fy 
                    let ax' = hnormalise hf ctxt env (substNames hf ax)
                    let ay' = hnormalise hf ctxt env (substNames hf ay)
                    ha <- un' False bnames ax' ay'
                    sc 1
                    combine bnames hf ha)
                (do ha <- un' False bnames ax ay
                    let fx' = hnormalise ha ctxt env (substNames ha fx)
                    let fy' = hnormalise ha ctxt env (substNames ha fy)
                    hf <- un' False bnames fx' fy'
                    sc 1
                    combine bnames hf ha)
       | otherwise 
          = do let (headx, argsx) = unApply appx
               let (heady, argsy) = unApply appy
               if (length argsx == length argsy && 
                   ((headx == heady) || (argsx == argsy) ||
                    (notFn headx && notFn heady))) then
                 do uf <- un' True bnames headx heady
                    unArgs uf argsx argsy
                 else unifyTmpFail appx appy
      where hnormalise [] _ _ t = t
            hnormalise ns ctxt env t = hnf ctxt env t
            checkHeads (P (DCon _ _) x _) (P (DCon _ _) y _)
                | x /= y = unifyFail appx appy
            checkHeads (P (TCon _ _) x _) (P (TCon _ _) y _)
                | x /= y = unifyFail appx appy
            checkHeads (P (DCon _ _) x _) (P (TCon _ _) y _)
                = unifyFail appx appy
            checkHeads (P (TCon _ _) x _) (P (DCon _ _) y _)
                = unifyFail appx appy
            checkHeads _ _ = return []

            unArgs as [] [] = return as
            unArgs as (x : xs) (y : ys) 
                = do let x' = hnormalise as ctxt env (substNames as x)
                     let y' = hnormalise as ctxt env (substNames as y) 
                     as' <- un' False bnames x' y'
                     vs <- combine bnames as as'
                     unArgs vs xs ys

            metavarApp tm = let (f, args) = unApply tm in
                                all (\x -> metavar x || notFn x) (f : args)
            metavar t = case t of
                             P _ x _ -> x `elem` holes || holeIn env x
                             _ -> False
            inenv t = case t of
                           P _ x _ -> x `elem` (map fst env) 
                           _ -> False

            notFn t = injective t || metavar t || inenv t 

    un' fn bnames x (Bind n (Lam t) (App y (P Bound n' _)))
        | n == n' = un' False bnames x y
    un' fn bnames (Bind n (Lam t) (App x (P Bound n' _))) y
        | n == n' = un' False bnames x y
--     un' fn bnames (Bind x (PVar _) sx) (Bind y (PVar _) sy) 
--         = un' False ((x,y):bnames) sx sy
--     un' fn bnames (Bind x (PVTy _) sx) (Bind y (PVTy _) sy) 
--         = un' False ((x,y):bnames) sx sy
    un' fn bnames (Bind x bx sx) (Bind y by sy) 
        = do h1 <- uB bnames bx by
             h2 <- un' False ((x,y):bnames) sx sy
             combine bnames h1 h2
    un' fn bnames x y 
        | OK True <- convEq' ctxt x y = do sc 1; return []
        | otherwise = do UI s f <- get
                         let r = recoverable x y
                         let err = CantUnify r
                                     topx topy (CantUnify r x y (Msg "") [] s) (errEnv env) s
                         if (not r) then lift $ tfail err
                           else do put (UI s ((x, y, env, err) : f))
                                   return [] -- lift $ tfail err

    unifyTmpFail x y 
                  = do UI s f <- get
                       let r = recoverable x y
                       let err = CantUnify r
                                   topx topy (CantUnify r x y (Msg "") [] s) (errEnv env) s
                       put (UI s ((x, y, env, err) : f))
                       return []

    -- shortcut failure, if we *know* nothing can fix it
    unifyFail x y = do UI s f <- get
                       let r = recoverable x y
                       let err = CantUnify r
                                   topx topy (CantUnify r x y (Msg "") [] s) (errEnv env) s
                       put (UI s ((x, y, env, err) : f))
                       lift $ tfail err


    uB bnames (Let tx vx) (Let ty vy)
        = do h1 <- un' False bnames tx ty
             h2 <- un' False bnames ty vy
             sc 1
             combine bnames h1 h2
    uB bnames (Guess tx vx) (Guess ty vy)
        = do h1 <- un' False bnames tx ty
             h2 <- un' False bnames ty vy
             sc 1
             combine bnames h1 h2
    uB bnames (Lam tx) (Lam ty) = do sc 1; un' False bnames tx ty
    uB bnames (Pi tx) (Pi ty) = do sc 1; un' False bnames tx ty
    uB bnames (Hole tx) (Hole ty) = un' False bnames tx ty
    uB bnames (PVar tx) (PVar ty) = un' False bnames tx ty
    uB bnames x y = do UI s f <- get
                       let r = recoverable (binderTy x) (binderTy y)
                       let err = CantUnify r topx topy
                                  (CantUnify r (binderTy x) (binderTy y) (Msg "") [] s)
                                  (errEnv env) s
                       put (UI s ((binderTy x, binderTy y, env, err) : f))
                       return [] -- lift $ tfail err

    checkCycle p@(x, P _ _ _) = return [p] 
    checkCycle (x, tm) 
        | not (x `elem` freeNames tm) = return [(x, tm)]
        | otherwise = lift $ tfail (InfiniteUnify x tm (errEnv env)) 

    combineArgs bnames args = ca [] args where
       ca acc [] = return acc
       ca acc (x : xs) = do x' <- combine bnames acc x
                            ca x' xs

    combine bnames as [] = return as
    combine bnames as ((n, t) : bs)
        = case lookup n as of 
            Nothing -> combine bnames (as ++ [(n,t)]) bs
            Just t' -> do ns <- un' False bnames t t'
                          -- make sure there's n mapping from n in ns
                          let ns' = filter (\ (x, _) -> x/=n) ns
                          sc 1
                          combine bnames as (ns' ++ bs)

    -- If there are any clashes of constructors, deem it unrecoverable, otherwise some
    -- more work may help.
    -- FIXME: Depending on how overloading gets used, this may cause problems. Better
    -- rethink overloading properly...

    recoverable (P (DCon _ _) x _) (P (DCon _ _) y _)
        | x == y = True
        | otherwise = False
    recoverable (P (TCon _ _) x _) (P (TCon _ _) y _)
        | x == y = True
        | otherwise = False
    recoverable (P (DCon _ _) x _) (P (TCon _ _) y _) = False
    recoverable (P (TCon _ _) x _) (P (DCon _ _) y _) = False
    recoverable p@(P _ n _) (App f a) = recoverable p f
--     recoverable (App f a) p@(P _ _ _) = recoverable f p
    recoverable (App f a) (App f' a')
        = recoverable f f' -- && recoverable a a'
    recoverable _ _ = True

errEnv = map (\(x, b) -> (x, binderTy b))

holeIn :: Env -> Name -> Bool
holeIn env n = case lookup n env of
                    Just (Hole _) -> True
                    _ -> False

