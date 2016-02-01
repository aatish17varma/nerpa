module Parse (nkplusGrammar) where

import Control.Applicative hiding (many,optional,Const)
import Text.Parsec hiding ((<|>))
import Text.Parsec.Expr
import Text.Parsec.Language
import qualified Text.Parsec.Token as T
import Data.Maybe

import Syntax
import Pos


reservedOpNames = ["!", "|", "=", ":=", "%", "+"]
reservedNames = ["and",
                 "bool",
                 "case",
                 "default",
                 "endrefine",
                 "false",
                 "filter",
                 "function",
                 "container",
                 "not",
                 "or",
                 "pkt",
                 "refine",
                 "role",
                 "send",
                 "struct",
                 "switch",
                 "true",
                 "typedef",
                 "uint"]


lexer = T.makeTokenParser (emptyDef {T.commentStart      = "(*"
                                    ,T.commentEnd        = "*)"
                                    ,T.nestedComments    = True
                                    ,T.identStart        = letter <|> char '_' 
                                    ,T.identLetter       = alphaNum <|> char '_'
                                    ,T.reservedOpNames   = reservedOpNames
                                    ,T.reservedNames     = reservedNames
                                    ,T.opLetter          = oneOf ":%*+./=|"
                                    ,T.caseSensitive     = True})


reservedOp = T.reservedOp lexer
reserved   = T.reserved lexer
identifier = T.identifier lexer
semiSep    = T.semiSep lexer
semiSep1   = T.semiSep1 lexer
colon      = T.colon lexer
commaSep   = T.commaSep lexer
commaSep1  = T.commaSep1 lexer
symbol     = T.symbol lexer
semi       = T.semi lexer
comma      = T.comma lexer
braces     = T.braces lexer
parens     = T.parens lexer
angles     = T.angles lexer
squares    = T.squares lexer
brackets   = T.brackets lexer
natural    = T.natural lexer
decimal    = T.decimal lexer
integer    = T.integer lexer
whiteSpace = T.whiteSpace lexer
lexeme     = T.lexeme lexer
dot        = T.dot lexer
stringLit  = T.stringLiteral lexer
charLit    = T.charLiteral lexer


removeTabs = do s <- getInput
                let s' = map (\c -> if c == '\t' then ' ' else c ) s 
                setInput s'          

withPos x = (\s x e -> atPos x (s,e)) <$> getPosition <*> x <*> getPosition


data SpecItem = SpType         TypeDef
              | SpFunc         Function
              | SpRole         Role
              | SpRoleLocation RoleLocation
              | SpSwitch       Switch


nkplusGrammar = Spec <$ removeTabs <*> ((optional whiteSpace) *> spec <* eof)

spec = (\r rs -> r:rs) <$> (withPos $ mkRefine [] <$> (many decl)) <*> (many refine)

mkRefine :: [String] -> [SpecItem] -> Refine
mkRefine targets items = Refine nopos targets types funcs roles locs sws
    where types = mapMaybe (\i -> case i of 
                                       SpType t -> Just t
                                       _        -> Nothing) items
          funcs = mapMaybe (\i -> case i of 
                                       SpFunc f -> Just f
                                       _        -> Nothing) items
          roles = mapMaybe (\i -> case i of 
                                       SpRole r -> Just r
                                       _        -> Nothing) items
          locs  = mapMaybe (\i -> case i of 
                                       SpRoleLocation l -> Just l
                                       _                -> Nothing) items
          sws   = mapMaybe (\i -> case i of 
                                       SpSwitch s -> Just s
                                       _          -> Nothing) items

refine = withPos $ mkRefine <$  reserved "refine" 
                            <*> (commaSep identifier)
                            <*> (many decl)
                            <*  reserved "endrefine"

decl =  (SpType         <$> typeDef)
    <|> (SpFunc         <$> func)
    <|> (SpRole         <$> role)
    <|> (SpRoleLocation <$> rloc)
    <|> (SpSwitch       <$> switch)


typeDef = withPos $ (flip $ TypeDef nopos) <$ reserved "typedef" <*> typeSpec <*> identifier

func = withPos $ Function nopos <$ reserved "function" <*> identifier <*> (parens $ commaSep arg) <*> (colon *> typeSpec)

role = withPos $ Role nopos <$  reserved "role" 
                            <*> identifier 
                            <*> (parens $ commaSep arg) 
                            <*> (option (EBool nopos True) (brackets $ expr))
                            <*> (reservedOp "=" *> stat)


rloc = withPos $ RoleLocation nopos <$ reserved "container" <*> (parens $ identifier) <* reservedOp "=" <*> expr

switch = withPos $ Switch nopos <$  reserved "switch" 
                                <*> identifier 
                                <*> (parens $ commaSep $ parens $ (,) <$> identifier <* comma <*> identifier)

arg = withPos $ (flip $ Field nopos) <$> typeSpec <*> identifier

typeSpec = withPos $ 
            uintType 
        <|> boolType 
        <|> userType 
        <|> structType 
        

uintType   = TUInt   nopos <$ reserved "uint" <*> (fromIntegral <$> angles decimal)
boolType   = TBool   nopos <$ reserved "bool"
userType   = TUser   nopos <$> identifier
structType = TStruct nopos <$  reserved "struct" <*> (braces $ commaSep1 arg)


expr =  buildExpressionParser etable term
    <?> "expression"

term    = parens expr <|> term'
term' = withPos $
         estruct
     <|> eapply
     <|> eloc
     <|> eint
     <|> ebool
     <|> epacket
     <|> eterm
     <|> econd

eapply = EApply nopos <$ isapply <*> identifier <*> (parens $ commaSep expr)
    where isapply = try $ lookAhead $ identifier *> symbol "("
eloc = ELocation nopos <$ isloc <*> identifier <*> (brackets $ commaSep expr)
    where isloc = try $ lookAhead $ identifier *> symbol "["
ebool = EBool nopos <$> ((True <$ reserved "true") <|> (False <$ reserved "false"))
epacket = EPacket nopos <$ reserved "pkt"
eterm = EKey nopos <$> identifier
econd = (fmap uncurry (ECond nopos <$ reserved "case"))
               <*> (braces $ (,) <$> (many $ (,) <$> expr <* colon <*> expr <* semi) 
                                 <*> (reserved "default" *> colon *> expr <* semi))
eint  = EInt nopos <$> (fromIntegral <$> decimal)
estruct = EStruct nopos <$ isstruct <*> identifier <*> (braces $ commaSep1 expr)
    where isstruct = try $ lookAhead $ identifier *> symbol "{"

etable = [[postf $ choice [postField]]
         ,[pref  $ choice [prefix "not" Not]]
         ,[binary "=" Eq AssocLeft]
         ,[binary "and" And AssocLeft]
         ,[binary "or" Or AssocLeft]
         ,[binary "%" Mod AssocLeft]
         ,[binary "+" Plus AssocLeft]
         ]

pref  p = Prefix  . chainl1 p $ return       (.)
postf p = Postfix . chainl1 p $ return (flip (.))
postField  = (\f end e -> EField (fst $ pos e, end) e f) <$> field <*> getPosition
field = dot *> identifier

prefix n fun = (\start e -> EUnOp (start, snd $ pos e) fun e) <$> getPosition <* reservedOp n
binary n fun = Infix $ (\le re -> EBinOp (fst $ pos le, snd $ pos re) fun le re) <$ reservedOp n


stat =  buildExpressionParser stable stat'
    <?> "statement"

stat' = parens stat <|> simpleStat

simpleStat = withPos $
              stest
          <|> ssend
          <|> sset

stest = STest nopos <$ reserved "filter" <*> expr
ssend = SSend nopos <$ reserved "send" <*> expr
sset  = SSet  nopos <$> expr <*> (reservedOp ":=" *> expr)

stable = [ [sbinary ";" SSeq AssocRight]
         , [sbinary "|" SPar AssocRight]
         ]

sbinary n fun = Infix $ (\l r -> fun (fst $ pos l, snd $ pos r) l r) <$ reservedOp n
