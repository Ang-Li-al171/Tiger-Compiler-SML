signature FRAME = 
sig 
	val wordSize: int
	type frame
  datatype register = Reg of string
  datatype access = InFrame of int
                  | InReg of Temp.temp

	val newFrame : {name: Temp.label,
					formals: bool list} -> frame
	val name : frame -> Temp.label
	val formals : frame -> access list
	val allocLocal : frame -> bool -> access

  val colorable : Temp.temp list
  val colorableRegs : register list

  val FP : Temp.temp
  val exp : access -> Tree.exp -> Tree.exp

  val RV : Temp.temp
  val procEntryExit1 : frame * Tree.stm -> Tree.stm

  val specialregs : Temp.temp list
  val argregs : Temp.temp list
  val calleesaves : Temp.temp list
  val callersaves : Temp.temp list

  val externalCall: string * Tree.exp list -> Tree.exp

  val tempMap: register Temp.table
  val setTempMap: register Temp.table -> unit

  val getTempName: Temp.temp -> string

  val getReg : Temp.temp -> register

  datatype frag = PROC of {body: Tree.stm, frame: frame}
                | STRING of Temp.label * string
end


structure MipsFrame :> FRAME = 
struct

  datatype access = InFrame of int
                  | InReg of Temp.temp
  type frame = {name: Temp.label, formals: access list, spOffset: int ref}

  datatype register = Reg of string
  
  datatype frag = PROC of {body: Tree.stm, frame: frame}
                | STRING of Temp.label * string
  (*sp is the offset for the stack pointer of the current frame from the fp*)

  structure Te = Temp
  structure Tr = Tree
  structure S = Symbol
  structure A = Assem

  val wordSize = 4

  val FP = Te.newtemp() (*FP should only be changed during Fn calls--> shifts into the level of the Fn*)
  val RV = Te.newtemp()
  val RA = Te.newtemp()
  val SP = Te.newtemp() 
  val ZERO = Te.newtemp()

  val v1 = Te.newtemp()   
 
  val a0 = Te.newtemp()   (* Arguments *)
  val a1 = Te.newtemp()   
  val a2 = Te.newtemp()   
  val a3 = Te.newtemp()   

  val t0 = Te.newtemp()   (* Temps*)
  val t1 = Te.newtemp()   
  val t2 = Te.newtemp()   
  val t3 = Te.newtemp()   
  val t4 = Te.newtemp()   
  val t5 = Te.newtemp()   
  val t6 = Te.newtemp()   
  val t7 = Te.newtemp()   
  val t8 = Te.newtemp()   
  val t9 = Te.newtemp()   
                            
  val s0 = Te.newtemp()   (* Saved Temps *)
  val s1 = Te.newtemp()   
  val s2 = Te.newtemp()   
  val s3 = Te.newtemp()   
  val s4 = Te.newtemp()   
  val s5 = Te.newtemp()   
  val s6 = Te.newtemp()   
  val s7 = Te.newtemp()   

  val tempMap = foldr (fn ((temp, regEntry), table) => Te.enter(table, temp, regEntry))
            Te.empty
            [(FP, Reg "$fp"),
             (RV, Reg "$v0"),
             (RA, Reg "$ra"),
             (SP, Reg "$sp"),
             (ZERO, Reg "$0"),
             (v1, Reg "$v1"),
             (a0, Reg "$a0"),
             (a1, Reg "$a1"),
             (a2, Reg "$a2"),
             (a3, Reg "$a3"),
             (t0, Reg "$t0"),
             (t1, Reg "$t1"),
             (t2, Reg "$t2"),
             (t3, Reg "$t3"),
             (t4, Reg "$t4"),
             (t5, Reg "$t5"),
             (t6, Reg "$t6"),
             (t7, Reg "$t7"),
             (t8, Reg "$t8"),
             (t9, Reg "$t9"),
             (s0, Reg "$s0"),
             (s1, Reg "$s1"),
             (s2, Reg "$s2"),
             (s3, Reg "$s3"),
             (s4, Reg "$s4"),
             (s5, Reg "$s5"),
             (s6, Reg "$s6"),
             (s7, Reg "$s7")]

  val myTempMap = ref tempMap

  val specialregs =  [FP, RV, RA, SP, ZERO, v1] 
  val argregs = [a0,a1,a2,a3] (* $a0-$a3 *)
  val calleesaves = [s0,s2,s2,s3,s4,s5,s6,s7] (* $s0-$s7 *)
  val callersaves = [t0,t1,t2,t3,t4,t5,t6,t7,t8,t9]  (* $t0-$t9 *)

  val colorable = calleesaves @ callersaves (* We can use s and t regs to load vars*)

  fun name({name = name, formals = _ , spOffset = _}) = name
  fun formals({name = _, formals = formals , spOffset = _}) = formals

  (*03/24/2014, currently assuming all formals are true--i.e. all parameters escape*)
  fun newFrame({name = name, formals = formals}) = 
    let val currOffset = ref 0
        fun allocFormals([]) = []
          | allocFormals(escape::rest) = (if escape
                                    then (currOffset := !currOffset-wordSize; InFrame(!currOffset)::allocFormals(rest))
                                    else InReg(Te.newtemp())::allocFormals(rest))
    in
      {name = name, formals = allocFormals(formals), spOffset = currOffset}
    end

  fun allocLocal({name = _, formals = _ , spOffset = spOffset}) = 
    let 
      val currOffset = spOffset
      fun allocL(escape) = (if escape
                            then (currOffset := !currOffset-wordSize; InFrame(!currOffset))
                            else InReg(Te.newtemp()))
    in
      allocL
    end

  fun exp(InFrame offset) = 
    let 
      fun addFP(fp: Tr.exp) = Tr.MEM(Tr.BINOP(Tr.PLUS, fp, Tr.CONST(offset)))
    in
      addFP
    end
  | exp(InReg t) = fn _ => Tr.TEMP(t)

  fun move(reg, var) = Tr.MOVE(Tr.TEMP(reg), Tr.TEMP(var))

  fun seq (stm::[]) = stm
    | seq (stm::rest) = Tr.SEQ(stm, seq(rest))
    | seq ([]) = Tr.EXP (Tr.CONST 0)

  fun moveArg (arg, access) =
      Tr.MOVE (exp access (Tr.TEMP(FP)), Tr.TEMP(arg))

  fun procEntryExit1 (frame, stm) =
    let
      val saved = RA :: calleesaves
      val tempRegs = map (fn temp => Temp.newtemp ()) saved
      val moveRegs = ListPair.mapEq move
      val saveRegs = seq ( moveRegs (tempRegs, saved))
      val restoreRegs = seq ( moveRegs (saved, tempRegs))
      (*This is all I know how to do*)
  in
      stm (*no idea what to do here*)
  end

  (*what does this do??... 04/18 by Ang*)
  fun procEntryExit2 (frame,body) =
      body @ 
      [A.OPER{assem="",
              src=specialregs @ calleesaves,
              dst=[],jump=SOME[]}]

(*I'll finish this soon...
  val argList = ref argregs
  val argPtr = ref ~4
  fun resetArgList() = argList := argregs
  fun nextArg() = case (!argList) of 
                  oneArgReg::others => (argList := others; oneArgReg)
                  | [] => (argPtr := !argPtr - 4; Translate.munchExp(exp (InFrame (!argPtr))))
  fun moveArgs(oneLocal : access) = 
    A.OPER{assem="move `d0, `s0",
           src=nextArg(),
           dst=,
           jump=NONE}*)

  fun procEntryExit3 ({name=name, formals=formals, locals=locals}, (*locals access list is not added yet...*)
                      body : Assem.instr list) =
    let
      val _ = ()
    in
      {prolog = "PROCEDURE " ^ Symbol.name name ^ "\n",
       body = body,
       epilog = "END " ^ Symbol.name name ^ "\n"}
    end

  fun externalCall(s, args) =
    Tr.CALL(Tr.NAME(Te.namedlabel s), args)


  fun getTempName(temp) =
    let 
      val name = Te.Table.look(!myTempMap, temp)
    in
      case name of NONE => Te.makestring(temp)
                 | SOME(Reg regstr) => regstr
    end

  fun getReg (temp) =
    let 
      val name = Te.Table.look(!myTempMap, temp)
    in
      case name of NONE => Reg "Undefined"
                 | SOME(regstr) => regstr
    end

  fun setTempMap (newTempMap) =
    myTempMap := newTempMap
  (*To my understanding, are these all the pre-colored regs???*)  
  val colorableRegs = map getReg colorable

end