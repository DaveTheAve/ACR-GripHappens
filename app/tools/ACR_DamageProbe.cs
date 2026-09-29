// Grip Happens read-only collision/steering routing probe 0.4.1,  No game calls, injection, hooks, writes or privilege changes.
// Narrowly pinned to the executable SHA-256 checked by Collect-CollisionRouting.ps1.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.ComponentModel;

public sealed class ACRDamageProbe : IDisposable
{
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr OpenProcess(uint access, bool inherit, int processId);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool ReadProcessMemory(IntPtr process, IntPtr address, byte[] buffer, UIntPtr size, out UIntPtr bytesRead);
    [DllImport("kernel32.dll", SetLastError=true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool CloseHandle(IntPtr handle);

    IntPtr handle;
    readonly ulong imageBase, imageEnd;
    ulong bytesReadTotal;
    int readCalls, errors;
    const ulong ReadBudget = 384UL * 1024 * 1024;
    const int CallBudget = 3000000;
    readonly Dictionary<uint,string> names = new Dictionary<uint,string>();
    readonly Dictionary<ulong,string> classNames = new Dictionary<ulong,string>();
    readonly Dictionary<ulong,List<string>> ancestors = new Dictionary<ulong,List<string>>();
    readonly Dictionary<ulong,int> objectIndices = new Dictionary<ulong,int>();
    readonly Dictionary<ulong,byte[]> objectHeaders = new Dictionary<ulong,byte[]>();
    readonly List<string> warnings = new List<string>();
    ulong namePool, chunks;
    int count;

    public ACRDamageProbe(int pid, ulong moduleBase, ulong moduleSize)
    {
        if (IntPtr.Size != 8) throw new InvalidOperationException("Use 64-bit PowerShell.");
        imageBase=moduleBase; imageEnd=checked(moduleBase+moduleSize);
        // PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ. Deliberately no write/operation rights.
        handle=OpenProcess(0x1010, false, pid);
        if(handle == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error(), "Cannot open ACR for read-only access.");
        namePool=checked(imageBase+0x0b27ba80UL);
    }
    public void Dispose() { if(handle!=IntPtr.Zero){ CloseHandle(handle);handle=IntPtr.Zero; } }
    static bool Ptr(ulong p) { return p>=0x10000UL && p<0x0000800000000000UL; }
    bool ImagePtr(ulong p) { return p>=imageBase && p<imageEnd; }
    byte[] Read(ulong address,int size)
    {
        if(!Ptr(address) || size<0 || size>2*1024*1024 || address+(ulong)size<address)
            throw new InvalidOperationException("Rejected address/length.");
        readCalls++;
        if(readCalls>CallBudget || bytesReadTotal+(ulong)size>ReadBudget)
            throw new InvalidOperationException("Read budget reached; no further memory is read.");
        byte[] b=new byte[size]; UIntPtr n;
        bool ok=ReadProcessMemory(handle,new IntPtr(unchecked((long)address)),b,new UIntPtr((uint)size),out n);
        bytesReadTotal+=n.ToUInt64();
        if(!ok || n.ToUInt64()!=(ulong)size) throw new Win32Exception(Marshal.GetLastWin32Error(),"ACR memory changed or is unreadable.");
        return b;
    }
    ulong U64(ulong p){ return BitConverter.ToUInt64(Read(p,8),0); }
    uint U32(ulong p){ return BitConverter.ToUInt32(Read(p,4),0); }
    int I32(ulong p){ return BitConverter.ToInt32(Read(p,4),0); }
    string Hex(ulong p){ return "0x"+p.ToString("x"); }
    void Warn(string s){ if(warnings.Count<60) warnings.Add(s); }
    string Name(uint id, uint number)
    {
        string s;
        if(!names.TryGetValue(id,out s))
        {
            uint block=id>>16, offset=id&65535;
            if(block>=8192) throw new InvalidOperationException("FName block exceeds bounds.");
            ulong b=U64(namePool+0x10UL+8UL*block);
            ulong entry=checked(b+2UL*offset);
            ushort head=BitConverter.ToUInt16(Read(entry,2),0);
            int len=head>>6; bool wide=(head&1)!=0;
            if(len<=0 || len>1023 || offset*2U+2U+(uint)(len*(wide?2:1))>131072U)
                throw new InvalidOperationException("FName entry failed validation.");
            s=(wide?Encoding.Unicode:Encoding.UTF8).GetString(Read(entry+2,len*(wide?2:1)));
            foreach(char c in s) if(c=='\0' || Char.IsControl(c)) throw new InvalidOperationException("Unexpected FName control character.");
            names[id]=s;
        }
        return number==0?s:s+"_"+(number-1).ToString();
    }
    byte[] Header(ulong obj)
    {
        byte[] h;
        if(objectHeaders.TryGetValue(obj,out h)) return h;
        int expected;
        if(!objectIndices.TryGetValue(obj,out expected)) throw new InvalidOperationException("Pointer is not in the captured UObject registry.");
        h=Read(obj,40);
        if(BitConverter.ToInt32(h,12)!=expected || !ImagePtr(BitConverter.ToUInt64(h,0)) || !Ptr(BitConverter.ToUInt64(h,16)))
            throw new InvalidOperationException("UObject header/registry mismatch.");
        objectHeaders[obj]=h; return h;
    }
    string ObjectName(ulong obj)
    {
        byte[] h=Header(obj);
        return Name(BitConverter.ToUInt32(h,24),BitConverter.ToUInt32(h,28));
    }
    string ClassName(ulong cls)
    {
        string s;
        if(!classNames.TryGetValue(cls,out s)) { s=ObjectName(cls);classNames[cls]=s; }
        return s;
    }
    string PathName(ulong obj)
    {
        if(obj==0)return "None";
        List<string> n=new List<string>(); HashSet<ulong> seen=new HashSet<ulong>();
        for(int i=0;i<12 && obj!=0;i++)
        {
            if(!seen.Add(obj)) {n.Add("<outer-cycle>");break;}
            byte[] h=Header(obj);n.Add(Name(BitConverter.ToUInt32(h,24),BitConverter.ToUInt32(h,28)));obj=BitConverter.ToUInt64(h,32);
        }
        n.Reverse();return String.Join(".",n.ToArray());
    }
    List<string> Ancestors(ulong cls)
    {
        List<string> a;
        if(ancestors.TryGetValue(cls,out a)) return a;
        a=new List<string>(); HashSet<ulong> seen=new HashSet<ulong>();ulong p=cls;
        for(int i=0;i<32 && p!=0;i++)
        {
            if(!seen.Add(p)) throw new InvalidOperationException("Class inheritance cycle.");
            a.Add(ClassName(p));
            p=U64(p+0x40); // UStruct::SuperStruct; registry validation before every class use.
        }
        ancestors[cls]=a;return a;
    }
    Dictionary<string,object> Ref(ulong obj)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["address"]=Hex(obj);
        if(obj==0){d["path"]="None";return d;}
        try{d["path"]=PathName(obj);d["class"]=ClassName(BitConverter.ToUInt64(Header(obj),16));}
        catch(Exception e){d["unresolved"]=e.Message;}
        return d;
    }
    Dictionary<string,object> Floats(ulong obj,int[] offsets,string[] labels)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        if(offsets.Length!=labels.Length)throw new InvalidOperationException("Field map mismatch.");
        for(int i=0;i<offsets.Length;i++)
        {
            float v=BitConverter.ToSingle(Read(checked(obj+(ulong)offsets[i]),4),0);
            d[labels[i]]=Single.IsNaN(v)||Single.IsInfinity(v)?(object)("non-finite: "+v.ToString()):(object)v;
        }
        return d;
    }
    Dictionary<string,object> GlobalSettings(ulong o)
    {
        Dictionary<string,object> d=Floats(o,
            new int[]{0x50,0xa8,0xac,0xb0,0xb4,0xb8,0xbc,0xc0,0xc4,0xc8},
            new string[]{"PuddlesGain","TiresConsumptionRate","FuelConsumptionRate","BrakesConsumptionRate","MechanicalDamageRate","CompressionDamageRate","PunctureProbability","DeflationDamageRate","RimStiffness","RimStiffnessTimeConst"});
        d["NumThreads"]=I32(o+0x3c);d["NumOdeThreads"]=I32(o+0x40);
        return d;
    }
    Dictionary<string,object> Material(ulong o)
    {
        Dictionary<string,object> d=Floats(o,
            new int[]{0xcc,0xd0,0xd4,0xd8,0xdc,0xe0,0xe4,0xe8,0x198},
            new string[]{"Friction","FrictionRain","FrictionSnow","FrictionReductionConstantWet","FrictionReductionConstantSnow","SlidingSpeedOptimalDry","SlidingSpeedOptimalWet","SlidingSpeedOptimalSnow","WearMultiplier"});
        d["CopyFrom"]=Ref(U64(o+0xa8));d["interpretation"]="Loaded asset fields, not a measurement of effective contact-patch grip. CopyFrom may supply effective properties.";
        return d;
    }
    Dictionary<string,object> Compound(ulong o)
    {
        Dictionary<string,object> d=Floats(o,new int[]{0x64,0x68,0x6c},new string[]{"TreadHeight","TreadConsumptionK","FlatSpotK"});
        d["WearCurve"]=Ref(U64(o+0x1c8));return d;
    }
    // Exact native layout recovered from the original serializer and consumption code.
    // No host/game pointers are followed by this pure decoder. It is also used by local tests.
    static object FiniteFloat(byte[] data, int offset)
    {
        float v=BitConverter.ToSingle(data,offset);
        return Single.IsNaN(v)||Single.IsInfinity(v)?(object)("non-finite: "+v.ToString()):(object)v;
    }
    static object Flag(byte[] data, int offset)
    {
        byte v=data[offset];return v<=1?(object)(v!=0):(object)("invalid flag: "+v.ToString());
    }
    public static Dictionary<string,object> DecodeNativeMaterialState(byte[] car, byte[] drive)
    {
        if(car==null || car.Length!=0x2c48)throw new ArgumentException("Native car fixture length mismatch.");
        if(drive!=null && drive.Length!=0x160)throw new ArgumentException("Native drivetrain fixture length mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["simulationActiveFlag"]=Flag(car,0x2c40);
        d["nativeStateFlag2c41"]=Flag(car,0x2c41);
        d["damagesEnabled"]=Flag(car,0x1240);
        d["brakeTemperatureConfigured"]=Flag(car,0x154);
        d["brakeThermalModelEnabled"]=Flag(car,0x1338+8);
        List<Dictionary<string,object>> wheels=new List<Dictionary<string,object>>();
        for(int w=0;w<4;w++)
        {
            int disc=0x1338+0x3c+20*w,pad=0x1338+0x8c+32*w;
            Dictionary<string,object> row=new Dictionary<string,object>();row["nativeWheelIndex"]=w;
            row["discTemperature"]=FiniteFloat(car,disc);
            row["discCoreTemperature"]=FiniteFloat(car,disc+4);
            row["discThickness"]=FiniteFloat(car,disc+8);
            row["discOverTempWearTime"]=FiniteFloat(car,disc+12);
            row["discMuOverheatingGain"]=FiniteFloat(car,disc+16);
            row["padTemperature"]=FiniteFloat(car,pad);
            row["padCoreTemperature"]=FiniteFloat(car,pad+4);
            row["padBackplateTemperature"]=FiniteFloat(car,pad+8);
            row["padThickness"]=FiniteFloat(car,pad+12);
            row["padMu"]=FiniteFloat(car,pad+16);
            row["padMuWearGain"]=FiniteFloat(car,pad+20);
            wheels.Add(row);
        }
        d["brakes"]=wheels;
        if(drive!=null)
        {
            Dictionary<string,object> clutch=new Dictionary<string,object>();
            clutch["currentThickness"]=FiniteFloat(drive,0x150);
            clutch["configuredWearRate"]=FiniteFloat(car,0x740);
            clutch["configuredMaximumThickness"]=FiniteFloat(car,0x744);
            clutch["configuredMinimumThickness"]=FiniteFloat(car,0x748);
            float current=BitConverter.ToSingle(drive,0x150), maximum=BitConverter.ToSingle(car,0x744);
            bool valid=!Single.IsNaN(current)&&!Single.IsInfinity(current)&&!Single.IsNaN(maximum)&&!Single.IsInfinity(maximum)&&maximum>0&&current>=0&&current<=maximum*1.001f;
            clutch["materialPercentageOfMaximum"]=valid?(object)(100.0*(double)current/(double)maximum):null;
            clutch["ratioValid"]=valid;d["clutchMaterial"]=clutch;
            List<Dictionary<string,object>> differentials=new List<Dictionary<string,object>>();
            // Native indices are preserved rather than guessing UI wheel/axle names.
            int[] configs=new int[]{0x53c,0x484,0x4e0};
            for(int i=0;i<3;i++)
            {
                int config=configs[i];Dictionary<string,object> row=new Dictionary<string,object>();
                row["nativeDifferentialIndex"]=i;
                row["currentPlateThickness"]=FiniteFloat(drive,0x154+4*i);
                row["configuredWearRate"]=FiniteFloat(car,config+0x48);
                row["configuredMinimumThickness"]=FiniteFloat(car,config+0x58);
                row["configuredPlateCount"]=BitConverter.ToInt32(car,config+0x10);
                differentials.Add(row);
            }
            d["differentialMaterial"]=differentials;
        }
        else d["drivetrainMaterialStatus"]="Not captured: no validated native drivetrain.";
        d["interpretation"]="Native material/temperature fields, NOT component-health percentages. Native indices and stored units are retained. One capture does not establish a rate, fade or wear progression; compare two captures of the same addresses and session. A true gate is not proof of a nonzero update.";
        return d;
    }
    // Pure configuration decoder, NOT a measured wheel toe/steering-force result.
    public static Dictionary<string,object> DecodeGeometryDamageInputs(byte[] car)
    {
        if(car==null || car.Length!=0x2c48)throw new ArgumentException("Geometry car fixture length mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["steeringOffsetEarlyOutFlag_b4"]=Flag(car,0xb4);
        d["steeringOffsetRaw_b4"]=(int)car[0xb4];
        List<Dictionary<string,object>> wheels=new List<Dictionary<string,object>>();
        for(int i=0;i<4;i++)
        {
            Dictionary<string,object> w=new Dictionary<string,object>();w["nativeWheelIndex"]=i;
            w["configuredMaxSteeringOffset"]=FiniteFloat(car,0x850+0xe0*i);
            w["geometryDamageControl"]=FiniteFloat(car,0x1280+4*i);
            w["damperMultiplier"]=FiniteFloat(car,0x1270+4*i);
            float maximum=BitConverter.ToSingle(car,0x850+0xe0*i),severity=BitConverter.ToSingle(car,0x1280+4*i);
            bool valid=!Single.IsNaN(maximum)&&!Single.IsInfinity(maximum)&&!Single.IsNaN(severity)&&!Single.IsInfinity(severity);
            float product=maximum*severity;
            valid=valid&&!Single.IsNaN(product)&&!Single.IsInfinity(product);
            w["unsignedDamageOffsetTerm"]=valid?(object)product:null;
            w["productInputsValid"]=valid;
            wheels.Add(w);
        }
        d["wheels"]=wheels;
        d["interpretation"]="Authored maximum steering-rod offset and native damage controls. unsignedDamageOffsetTerm is a calculated Float32 product BEFORE native sign, steering input and constraint processing, NOT observed wheel alignment, degrees, metres or steering pull. The raw b4 flag is checked for a nonzero early-out in the audited steering-offset routine; no additional meaning is assigned.";
        return d;
    }
    void ValidateGeometryDamageLayout()
    {
        ValidateMaterialAnchor(0x4f35700UL,"f3410f10ac8180120000","Wheel geometry severity reader");
        ValidateMaterialAnchor(0x4f35735UL,"f3420f10840a50080000","Authored maximum steering offset reader");
        ValidateMaterialAnchor(0x4f3562fUL,"4180b9b4000000000f85cd010000","Native steering-offset early-out");
        ValidateMaterialAnchor(0x4f4e790UL,"486341104869d0e0000000488b41084805e80700004803c2c3","Per-wheel suspension configuration stride");
    }
    void ValidateMaterialLayout()
    {
        ValidateMaterialAnchor(0x4f46e7dUL, "4438bb402c000074674438bb40120000745e488b", "Clutch wear gates");
        ValidateMaterialAnchor(0x4f453e0UL, "83ba98000000024d8bd10f85a5000000458b5910", "Differential wear entry");
        ValidateMaterialAnchor(0x4ef8158UL, "4438a554010000741e453866087418498b064438", "Brake thermal gates");
        ValidateMaterialAnchor(0x4f58b92UL, "4c8b86100300004c8d4c24484c2b860803000048", "Native car collection serializer");
        ValidateMaterialAnchor(0x4f43a50UL, "488b81f0000000f30f108150010000f30f5e8044", "Clutch thickness getter");
    }
    void ValidateMaterialAnchor(ulong rva,string expected,string label)
    {
        byte[] actual=Read(checked(imageBase+rva),expected.Length/2);
        for(int i=0;i<actual.Length;i++)
            if(actual[i]!=Convert.ToByte(expected.Substring(i*2,2),16))
                throw new InvalidOperationException("Material layout instruction mismatch: "+label+". This optional chapter was not decoded.");
    }
    // Read-only observation decoder. Counters count native evaluations, not button presses.
    public static Dictionary<string,object> DecodeShiftObservations(byte[] bytes,ulong drivetrain)
    {
        if(bytes==null||(bytes.Length!=768&&bytes.Length!=1024))throw new ArgumentException("Observation table extent mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();int found=-1,occupied=0,stride=bytes.Length/8;
        for(int i=0;i<8;i++) {
            ulong owner=BitConverter.ToUInt64(bytes,i*stride);if(owner!=0)occupied++;
            if(owner==drivetrain&&drivetrain!=0){if(found!=-1)throw new ArgumentException("Ambiguous observation owner.");found=i;}
        }
        d["occupiedSlots"]=occupied;d["availableSlots"]=8;
        if(found<0){d["status"]="No matching observation slot; no history conclusion";return d;}
        int p=found*stride;ulong calls=BitConverter.ToUInt64(bytes,p+8),accepted=BitConverter.ToUInt64(bytes,p+16),failed=BitConverter.ToUInt64(bytes,p+24),blocked=BitConverter.ToUInt64(bytes,p+32);
        if(accepted>calls||failed>calls||blocked>calls||checked(accepted+failed+blocked)>calls)
            throw new ArgumentException("Observation counters are inconsistent or changed during reading.");
        d["status"]="Captured";d["admissionCalls"]=calls;d["acceptedEvaluations"]=accepted;
        d["failedEvaluations"]=failed;d["cooldownBlocks"]=blocked;
        d["overrevUpdates"]=BitConverter.ToUInt64(bytes,p+40);d["grindingUpdates"]=BitConverter.ToUInt64(bytes,p+80);
        d["observedPeakRpm"]=FiniteFloat(bytes,p+48);d["lastObservedRpm"]=FiniteFloat(bytes,p+52);
        if(stride==128) {
            d["lastAdmissionRngState"]=BitConverter.ToUInt32(bytes,p+88);
            d["coupledOverrevStressUpdates"]=BitConverter.ToUInt64(bytes,p+96);
            d["coupledOverrevExposureSeconds"]=FiniteFloat(bytes,p+104);
            d["stressExposureMeaning"]="Exposure uses the selected gearbox tuning: Engagement 0.02 or Consequences 0.50 seconds per excess revolution, x100 into component wear. Requires a lower engaged gear and coupled clutch. Not shift attempts or wall impacts.";
        }
        d["damageRpmThreshold"]=FiniteFloat(bytes,p+56);d["lastGearboxControl"]=FiniteFloat(bytes,p+60);
        d["lastNativeGearboxLife"]=FiniteFloat(bytes,p+64);
        d["lastCurrentGearIndex"]=BitConverter.ToInt32(bytes,p+68);d["lastTargetInputIndex"]=BitConverter.ToInt32(bytes,p+72);
        d["lastTimedBranchFlag"]=Flag(bytes,p+76);d["rawDownshiftProtectionFlag"]=Flag(bytes,p+77);
        d["meaning"]="Bounded process-lifetime observations for this drivetrain address. Admission evaluations are not distinct button presses or completed shifts. Peak RPM is only observed at admission/overrev updates. Addresses may be reused; compare matching car instances and counters. Stored protection flag can remain true despite a local bypass.";
        return d;
    }
    bool MechanicalObservationEnabled()
    {
        string code=RoutingHex(Read(imageBase+0x04f44b00UL,8));
        if(code=="f30f108144010000")return false;
        if(code=="e91bd9ddfb909090")return true;
        throw new InvalidOperationException("Unknown native admission entry; observation chapter rejected.");
    }
    Dictionary<string,object> ShiftObservations(ulong drive)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        try {
            if(!MechanicalObservationEnabled()){d["status"]="Observation mode not installed";return d;}
            int length=RoutingHex(Read(imageBase+0x04f4cb7cUL,8))=="e80f5bddfb909090"?1024:768;
            byte[] a=Read(imageBase+0x0b642a00UL,length);
            d=DecodeShiftObservations(a,drive);
            d["stableAcrossRead"]=SameBytes(a,Read(imageBase+0x0b642a00UL,length));
            if(!(bool)d["stableAcrossRead"])d["status"]="Observation table changed during read; discard values";
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["readOnly"]=true;return d;
    }
    public static Dictionary<string,object> DecodePowertrainInputs(byte[] drive,byte[] config,byte[] car)
    {
        if(drive==null||drive.Length!=0x160||config==null||config.Length!=0x268||car==null||car.Length!=0x2c48)
            throw new ArgumentException("Powertrain input extent mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["nativeRestartThresholdRpm"]=FiniteFloat(drive,0x1c);
        d["nativeStarterActive"]=Flag(drive,0x34);d["nativeStarterOverrideFlag"]=Flag(drive,0x35);
        d["nativeEngineOutputTorque"]=FiniteFloat(drive,0x5c);
        d["nativeEngineTorqueBeforeStarter"]=FiniteFloat(drive,0x58);
        d["nativeSteerCommand"]=FiniteFloat(car,0x1328);d["nativeThrottleCommand"]=FiniteFloat(car,0x1320);d["nativeBrakeCommand"]=FiniteFloat(car,0x1324);
        d["engineRpm"]=FiniteFloat(drive,0x48);d["configuredLimiterRpm"]=BitConverter.ToInt32(config,0x214);
        d["configuredDamageRpmThreshold"]=FiniteFloat(config,0x248);
        d["rawDownshiftProtection"]=Flag(drive,0x114);d["downshiftProtectionWindow"]=BitConverter.ToInt32(drive,0x118);
        d["nativeEngineRpmAccumulator"]=FiniteFloat(car,0x12d4);
        d["manualTargetInputIndex"]=BitConverter.ToInt32(car,0x1318);d["shiftUpInput"]=Flag(car,0x1310);d["shiftDownInput"]=Flag(car,0x1311);
        d["meaning"]="Instantaneous native RPM and authored thresholds, not proof of actual overrev or gear engagement. Zero threshold disables this authored overrev accumulator. Native force/neutral/assist behavior is separate.";
        return d;
    }
    public static List<Dictionary<string,object>> DecodeTyreForceFrames(byte[] car)
    {
        if(car==null||car.Length!=0x2c48)throw new ArgumentException("Tyre-frame car extent mismatch.");
        List<Dictionary<string,object>> rows=new List<Dictionary<string,object>>();
        for(int wheel=0;wheel<4;wheel++) {
            int offset=0x15f0+wheel*0x478;Dictionary<string,object> d=new Dictionary<string,object>();rows.Add(d);
            d["nativeWheelIndex"]=wheel;d["storedTyreIndex"]=BitConverter.ToInt32(car,offset+0x18);
            try {
                if((int)d["storedTyreIndex"]!=wheel)throw new ArgumentException("Tyre index does not match the audited array slot.");
                double[] basis=new double[9];for(int i=0;i<9;i++)basis[i]=JointFinite(car,offset+0x1d0+8*i);
                for(int r=0;r<3;r++)for(int c=0;c<3;c++) {
                    double dot=0;for(int k=0;k<3;k++)dot+=basis[r*3+k]*basis[c*3+k];
                    if(Math.Abs(dot-(r==c?1:0))>0.005)throw new ArgumentException("Tyre force-frame basis not orthonormal.");
                }
                d["basisRows"]=basis;d["basisRow2HeadingDegrees"]=Math.Atan2(basis[6],basis[8])*180/Math.PI;
                d["positionX"]=JointFinite(car,offset+0x218);d["positionY"]=JointFinite(car,offset+0x220);d["positionZ"]=JointFinite(car,offset+0x228);
                d["velocityX"]=JointFinite(car,offset+0x230);d["velocityY"]=JointFinite(car,offset+0x238);d["velocityZ"]=JointFinite(car,offset+0x240);
                d["kinematicLateralVelocity"]=basis[0]*JointFinite(car,offset+0x230)+basis[1]*JointFinite(car,offset+0x238)+basis[2]*JointFinite(car,offset+0x240);
                d["kinematicForwardVelocity"]=basis[6]*JointFinite(car,offset+0x230)+basis[7]*JointFinite(car,offset+0x238)+basis[8]*JointFinite(car,offset+0x240);
                d["nativeWheelAngularVelocity"]=FiniteFloat(car,offset+0x3a0);
                d["nativeWheelLocked"]=Flag(car,offset+0x3a4);
                byte[] bounded=new byte[0x478];Array.Copy(car,offset,bounded,0,bounded.Length);d["boundedTyreStateHex"]=RoutingHex(bounded);

                d["hasGroundContact"]=Flag(car,offset+0x248);
                string[] names={"Position","Speed","Omega","Csi","Force"};
                for(int i=0;i<5;i++) {d["lateral"+names[i]]=FiniteFloat(car,offset+0x450+4*i);d["longitudinal"+names[i]]=FiniteFloat(car,offset+0x464+4*i);}
                d["status"]="Captured";
            }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
            d["meaning"]="Native tyre force-frame basis and tyre-centre kinematics; older lateral/longitudinal scalar fields are not certified contact-force output. World heading includes car yaw and steering; it is not certified wheel toe/camber. A paused sample is not driving history. Contact flag is read from nested TyreState+0x78, at tyre+0x248; older RC13 reports used the wrong base. No tyre state was modified.";
        }
        return rows;
    }

    bool gameplayConfigured, gameplayExtended, gameplayOperationalSupported;
    ulong gameplayDataRva;
    readonly HashSet<string> gameplayFeatures = new HashSet<string>(StringComparer.Ordinal);
    public static void ValidateGameplayFeatures(string[] features) {
        if(features==null||features.Length>8)throw new ArgumentException("Invalid gameplay feature list.");
        var seen=new HashSet<string>(StringComparer.Ordinal);
        foreach(string feature in features) {
            if(feature!="GearboxProgression" && feature!="DifferentialWearRate" && feature!="SuspensionAlignmentDegrees" && feature!="SuspensionCamberDegrees" && feature!="CoolingConsequences" && feature!="HudDamageWarnings" && feature!="EngineUseWearScale" && feature!="EngineWearAudit")throw new ArgumentException("Unknown gameplay feature: "+feature);
            if(!seen.Add(feature))throw new ArgumentException("Duplicate gameplay feature: "+feature);
        }
    }
    public Dictionary<string,string> ConfigureGameplay(ulong codeRva,ulong dataRva,byte[] expectedCode,ulong[] sites,string[] labels,string[] expectedHex,string[] features)
    {
        if(expectedCode==null || (expectedCode.Length!=0 && expectedCode.Length!=8192) || sites==null || labels==null || expectedHex==null || sites.Length!=15 || labels.Length!=15 || expectedHex.Length!=15)
            throw new ArgumentException("Invalid bounded gameplay verification request.");
        ValidateGameplayFeatures(features);
        var result=new Dictionary<string,string>();
        for(int i=0;i<sites.Length;i++) {
            byte[] expected=GameplayHex(expectedHex[i]);
            if(expected.Length<5 || expected.Length>64 || !ImagePtr(imageBase+sites[i]) || !ImagePtr(imageBase+sites[i]+(ulong)expected.Length-1))throw new ArgumentException("Gameplay entry outside the loaded module.");
            byte[] actual=Read(imageBase+sites[i],expected.Length);
            if(!SameBytes(actual,expected))throw new InvalidOperationException("Live gameplay entry mismatch: "+labels[i]);
            result.Add(labels[i],RoutingHex(actual));
        }
        gameplayExtended=expectedCode.Length!=0;
        gameplayOperationalSupported=gameplayExtended && Encoding.ASCII.GetString(expectedCode,0x1dc0,16)=="GH20-OPSTATE-001";
        if(gameplayExtended) {
            if(!ImagePtr(imageBase+codeRva) || !ImagePtr(imageBase+codeRva+8191) || !ImagePtr(imageBase+dataRva+4095))throw new InvalidOperationException("Gameplay sections are absent from the loaded module.");
            if(!SameBytes(Read(imageBase+codeRva,8192),expectedCode))throw new InvalidOperationException("Complete live gameplay helper section did not match the verified file.");
        }
        gameplayFeatures.Clear();foreach(string feature in features){gameplayFeatures.Add(feature);}
        if(!gameplayExtended && gameplayFeatures.Count!=0)throw new InvalidOperationException("An active extension has no verified code section.");
        engineUseWearScale=1.0f;
        if(gameplayFeatures.Contains("EngineUseWearScale")||gameplayFeatures.Contains("EngineWearAudit")){engineUseWearScale=BitConverter.ToSingle(expectedCode,0x8f0);if(Single.IsNaN(engineUseWearScale)||Single.IsInfinity(engineUseWearScale)||engineUseWearScale<0||engineUseWearScale>2)throw new ArgumentException("Invalid engine-use wear multiplier.");}
        gameplayDataRva=dataRva;gameplayConfigured=true;return result;
    }
    static byte[] GameplayHex(string text) {
        if(text==null || text.Length>128 || text.Length%2!=0)throw new ArgumentException("Invalid entry bytes");
        var result=new byte[text.Length/2];for(int i=0;i<result.Length;i++)result[i]=Convert.ToByte(text.Substring(i*2,2),16);return result;
    }
    public static Dictionary<string,object> DecodeEngineWearAudit(byte[] row) {
        if(row==null||row.Length!=128)throw new ArgumentException("Engine accounting extent mismatch.");
        uint sequence=BitConverter.ToUInt32(row,24);if((sequence&1)!=0)throw new ArgumentException("Engine accounting update is in progress.");
        ulong calls=BitConverter.ToUInt64(row,32),valid=BitConverter.ToUInt64(row,40),invalid=BitConverter.ToUInt64(row,112);
        if(calls>9007199254740991UL||valid>calls||invalid>calls||valid+invalid!=calls)throw new ArgumentException("Engine accounting counts are invalid.");
        var d=new Dictionary<string,object>{{"evaluations",calls},{"validEvaluations",valid},{"invalidEvaluations",invalid},{"sequence",sequence}};
        string[] keys={"nativeUseProposal","scaledUseProposal","overspeedProposal","boostProposal","totalRequestedLoss","floatRoundedRequestedLoss","observedHealthDecrease","observedHealthRecovery"};
        for(int i=0;i<keys.Length;i++){
            double n=BitConverter.ToDouble(row,48+8*i);if(Double.IsNaN(n)||Double.IsInfinity(n)||n<0)throw new ArgumentException("Engine accounting value is invalid: "+keys[i]);d[keys[i]]=n;
        }
        float life=BitConverter.ToSingle(row,28);if(Single.IsNaN(life)||Single.IsInfinity(life)||life<0)throw new ArgumentException("Engine accounting life is invalid.");
        d["busySkippedEvaluations"]=BitConverter.ToUInt32(row,124);d["previousObservedHealth"]=life;d["partIndex"]=BitConverter.ToUInt32(row,120);d["status"]="Captured";
        d["meaning"]="Cumulative counters at the Engine routine-use policy call. Proposal totals are before native health-setter restrictions; observed health changes between calls can include other policies/collisions. Take endpoint differences, not a sum of sampled totals. Missing/locked/reset counters are not zero.";
        return d;
    }
    Dictionary<string,object> EngineWearAuditObservation(ulong car) {
        var disabled=new Dictionary<string,object>{{"status","Disabled"}};
        if(!gameplayConfigured||!gameplayFeatures.Contains("EngineWearAudit"))return disabled;
        try {
            List<ulong[]> parts;if(!warningParts.TryGetValue(car,out parts))return new Dictionary<string,object>{{"status","No approved Engine part"}};
            ulong[] target=null;foreach(var p in parts)if(String.Equals(warningPartNames[p[0]],"Engine",StringComparison.OrdinalIgnoreCase)){if(target!=null)throw new InvalidOperationException("Ambiguous Engine part for accounting.");target=p;}
            if(target==null)return new Dictionary<string,object>{{"status","No approved Engine part"}};
            if(U64(target[0]+0x10)!=target[3]||U32(target[0]+12)!=target[4]||U64(target[0]+0x20)!=target[1]||U64(target[1]+0x20)!=target[2]||U64(target[2]+0x580)!=car)throw new InvalidOperationException("Engine accounting owner changed.");
            ulong start=imageBase+gameplayDataRva+0x800;byte[] table=Read(start,2048);int occupied=0;
            for(int i=0;i<16;i++) {
                int offset=i*128;ulong part=BitConverter.ToUInt64(table,offset);if(part!=0)occupied++;
                if(part!=target[0]||BitConverter.ToUInt64(table,offset+8)!=target[1]||BitConverter.ToUInt64(table,offset+16)!=target[2]||BitConverter.ToUInt32(table,offset+120)!=target[4])continue;
                byte[] row=new byte[128];Array.Copy(table,offset,row,0,128);var result=DecodeEngineWearAudit(row);
                bool stable=SameBytes(row,Read(start+(ulong)offset,128))&&U64(target[2]+0x580)==car&&U32(target[0]+12)==target[4];
                result["stableAcrossRead"]=stable;result["partAddress"]=Hex(part);result["ownerAddress"]=Hex(target[1]);result["actorAddress"]=Hex(target[2]);result["slot"]=i;
                if(!stable)result["status"]="Changed during read; discard this counter sample";
                return result;
            }
            return new Dictionary<string,object>{{"status",occupied==16?"Accounting table full; no counter slot for this Engine":"No initialized accounting slot for this Engine"},{"occupiedSlots",occupied},{"maximumSlots",16}};
        }catch(Exception e){return new Dictionary<string,object>{{"status","Unavailable"},{"error",e.Message}};}
    }

    public static Dictionary<string,object> DecodeModeledCooling(byte[] table,ulong car,ulong drive)
    {
        if(table==null || table.Length!=1024)throw new ArgumentException("Cooling table extent mismatch.");
        var d=new Dictionary<string,object>();int occupied=0;
        for(int i=0;i<32;i++) {
            int offset=i*32;ulong owner=BitConverter.ToUInt64(table,offset);if(owner!=0)occupied++;
            if(owner!=drive || BitConverter.ToUInt64(table,offset+8)!=car)continue;
            float temperature=BitConverter.ToSingle(table,offset+16),exposure=BitConverter.ToSingle(table,offset+20);
            uint flags=BitConverter.ToUInt32(table,offset+28);
            if(Single.IsNaN(temperature)||Single.IsInfinity(temperature)||temperature<25||temperature>180||Single.IsNaN(exposure)||Single.IsInfinity(exposure)||exposure<0||flags>3)throw new ArgumentException("Invalid modeled cooling state.");
            d["status"]="Captured";d["modeledTemperatureC"]=temperature;d["addedNativeEngineWearExposure"]=exposure;
            d["updateCount"]=BitConverter.ToUInt32(table,offset+24);d["modeFlags"]=flags;d["overheating"]=(flags&2)!=0;
        }
        if(!d.ContainsKey("status"))d["status"]=occupied==32?"Bounded table full; no state for this car":"No initialized modeled state for this car";
        d["occupiedSlots"]=occupied;d["maximumSlots"]=32;
        d["meaning"]="Grip Happens modeled radiator-temperature state, NOT a native coolant sensor, coolant volume, or real-world calibration. Exposure feeds the native engine-wear accumulator; it is not an immediate torque percentage.";
        return d;
    }
    public static Dictionary<string,object> DecodeEffectiveGearbox(byte[] car,byte[] drive,bool extension)
    {
        if(car==null||car.Length!=0x2c48||drive==null||drive.Length!=0x160)throw new ArgumentException("Gearbox input extent mismatch.");
        var d=new Dictionary<string,object>();float q=BitConverter.ToSingle(car,0x1260),life=BitConverter.ToSingle(drive,0x120),maximum=BitConverter.ToSingle(car,0x5c0);
        bool valid=!Single.IsNaN(q)&&!Single.IsInfinity(q)&&q>=0&&!Single.IsNaN(life)&&!Single.IsInfinity(life)&&life>=0&&!Single.IsNaN(maximum)&&!Single.IsInfinity(maximum)&&maximum>0;
        bool active=extension&&car[0x1240]!=0&&car[0x2c40]!=0;
        d["extensionEnabled"]=extension;d["nativeSimulationAndDamageActive"]=active;d["inputsValid"]=valid;
        if(valid){double fraction=Math.Min(1,(double)life/maximum);d["internalLifeFraction"]=fraction;d["rawComponentControl"]=q;d["effectiveShiftControl"]=active?Math.Min(q,Math.Sqrt(fraction)):(double)q;}
        d["meaning"]="Derived control from the verified helper formula, not a measured failure probability or a count of completed shifts. Native component control and internal life remain distinct.";
        return d;
    }
    public static Dictionary<string,object> DecodeEngineOperationalFeedback(byte[] data,ulong car,ulong drive) {
        if(data==null||data.Length!=1024)throw new ArgumentException("Engine feedback table extent mismatch.");
        var d=new Dictionary<string,object>();int matches=0,occupied=0;
        for(int i=0;i<32;i++) {
            int p=i*32;ulong owner=BitConverter.ToUInt64(data,p);if(owner!=0)occupied++;
            if(owner!=drive+8||BitConverter.ToUInt64(data,p+8)!=car)continue;
            if(++matches>1)throw new ArgumentException("Ambiguous engine feedback owner.");
            float seconds=BitConverter.ToSingle(data,p+16),rpm=BitConverter.ToSingle(data,p+28);
            uint flag=BitConverter.ToUInt32(data,p+20);
            if(Single.IsNaN(seconds)||Single.IsInfinity(seconds)||seconds<0||seconds>1.501||flag>1)throw new ArgumentException("Invalid engine feedback state.");
            d["status"]="Captured";d["failedRestartSeconds"]=seconds;d["operationalCritical"]=flag==1;
            d["updateCount"]=BitConverter.ToUInt32(data,p+24);d["observedRpm"]=Single.IsNaN(rpm)||Single.IsInfinity(rpm)?(object)null:rpm;
        }
        if(matches==0)d["status"]="No initialized engine-feedback state";
        d["occupiedSlots"]=occupied;d["maximumSlots"]=32;
        d["meaning"]="Display-only operational warning, not zero component health: a damaged engine failed to reach max(native restart threshold,800 RPM) under requested throttle for1.5s in neutral or with the clutch disengaged. Clears after restart/repair. No engine torque or health is changed by this observer.";
        return d;
    }
    Dictionary<string,object> GameplayObservation(ulong car,ulong drive,byte[] carBytes,byte[] driveBytes)
    {
        var d=new Dictionary<string,object>();d["configuredAndVerified"]=gameplayConfigured;
        d["extendedCodeVerified"]=gameplayConfigured&&gameplayExtended;
        d["gearbox"]=DecodeEffectiveGearbox(carBytes,driveBytes,gameplayConfigured&&gameplayFeatures.Contains("GearboxProgression"));
        d["differentialZeroRateFallbackEnabled"]=gameplayConfigured&&gameplayFeatures.Contains("DifferentialWearRate");
        d["damageAlignmentEnabled"]=gameplayConfigured&&gameplayFeatures.Contains("SuspensionAlignmentDegrees");
        d["gameplayRecipe"]=gameplayOperationalSupported?"Current":"Base";
        d["correctedCamberAxis"]=gameplayOperationalSupported&&gameplayFeatures.Contains("SuspensionCamberDegrees");
        if(gameplayConfigured&&gameplayOperationalSupported&&gameplayFeatures.Contains("HudDamageWarnings")) {
            try {
                byte[] first=Read(imageBase+gameplayDataRva+0x400,1024);
                var feedback=DecodeEngineOperationalFeedback(first,car,drive);
                feedback["stableAcrossRead"]=SameBytes(first,Read(imageBase+gameplayDataRva+0x400,1024));
                d["engineOperationalFeedback"]=feedback;
            }catch(Exception e){d["engineOperationalFeedback"]=new Dictionary<string,object>{{"status","Unavailable"},{"error",e.Message}};}
        } else d["engineOperationalFeedback"]=new Dictionary<string,object>{{"status","Not installed in this verified recipe"}};

        if(gameplayConfigured&&gameplayFeatures.Contains("CoolingConsequences")) {
            try {
                byte[] first=Read(imageBase+gameplayDataRva,1024);
                var cooling=DecodeModeledCooling(first,car,drive);
                cooling["stableAcrossRead"]=SameBytes(first,Read(imageBase+gameplayDataRva,1024));
                if(!(bool)cooling["stableAcrossRead"])cooling["status"]="Changed during read; do not use this sample for exact deltas";
                d["modeledCooling"]=cooling;
            } catch(Exception e){d["modeledCooling"]=new Dictionary<string,object>{{"status","Unavailable"},{"error",e.Message}};}
        } else d["modeledCooling"]=new Dictionary<string,object>{{"status","Extension disabled"}};
        return d;
    }

    Dictionary<string,object> NativeMaterials(ulong engine)
    {
        Dictionary<string,object> result=new Dictionary<string,object>();result["readOnly"]=true;
        List<Dictionary<string,object>> cars=new List<Dictionary<string,object>>();result["cars"]=cars;
        try
        {
            ValidateMaterialLayout();
            result["layoutInstructionChecksPassed"]=true;
            // Engine serializer at 0x144f58b92 / 0x144f51185: vector<Car*> +0x308.
            byte[] vector=Read(engine+0x308,24);
            ulong first=BitConverter.ToUInt64(vector,0),end=BitConverter.ToUInt64(vector,8),capacity=BitConverter.ToUInt64(vector,16);
            if(first==0 && end==0 && capacity==0){result["status"]="No initialized car vector";return result;}
            if(!Ptr(first)||!Ptr(end)||!Ptr(capacity)||((first|end|capacity)&7UL)!=0||end<first||capacity<end||(end-first)%8!=0||(capacity-first)%8!=0||end-first>32*8UL||capacity-first>4096*8UL)
                throw new InvalidOperationException("Native car vector failed bounds checks.");
            int n=(int)((end-first)/8);
            if(n==0){result["status"]="No initialized cars";result["readOnly"]=true;return result;}
            byte[] pointers=Read(first,n*8);
            for(int i=0;i<n;i++)
            {
                ulong car=BitConverter.ToUInt64(pointers,i*8);
                Dictionary<string,object> row=new Dictionary<string,object>();row["nativeCarIndex"]=i;row["carAddress"]=Hex(car);cars.Add(row);
                try
                {
                    if((car&7UL)!=0)throw new InvalidOperationException("Unaligned native car pointer.");
                    byte[] data=Read(car,0x2c48);
                    ulong link=BitConverter.ToUInt64(data,8);
                    // Brake routine establishes Car+8 -> native-engine owner -> engine.
                    if(!Ptr(link)||U64(link)!=engine || BitConverter.ToUInt64(data,0x1338)!=car)
                        throw new InvalidOperationException("Car/engine or embedded-brake back-reference mismatch.");
                    byte[] drive=null;ulong holder=BitConverter.ToUInt64(data,0x28c0),drivetrain=0;
                    if(Ptr(holder))
                    {
                        try
                        {
                            drivetrain=U64(holder);
                            byte[] candidate=Read(drivetrain,0x160);
                            if(!ImagePtr(BitConverter.ToUInt64(candidate,0)) || BitConverter.ToUInt64(candidate,0xf0)!=car)
                                throw new InvalidOperationException("Drivetrain identity/back-reference mismatch.");
                            drive=candidate;row["drivetrainAddress"]=Hex(drivetrain);
                        }
                        catch(Exception e){row["drivetrainReadError"]=e.Message;}
                    }
                    Dictionary<string,object> state=DecodeNativeMaterialState(data,drive);
                    if(drive!=null)row["gameplayExtensions"]=GameplayObservation(car,drivetrain,data,drive);
                    try {
                        ValidateDamageTraceLayout();
                        byte[] damageBlock=new byte[0x90];Array.Copy(data,0x1240,damageBlock,0,damageBlock.Length);
                        row["nativeDamageControls"]=DecodeDamageControls(damageBlock,true);
                    } catch(Exception e){row["nativeDamageControlsError"]=e.Message;}
                    try {
                        ValidateGeometryDamageLayout();
                        row["geometryDamageInputs"]=DecodeGeometryDamageInputs(data);
                        AddEffectiveGeometryInputs((Dictionary<string,object>)row["geometryDamageInputs"],GeometryBoostEnabled());
                    } catch(Exception e){row["geometryDamageInputsError"]=e.Message;}
                    if(drive!=null) {
                        try {
                            ValidateMaterialAnchor(0x4f445d1UL,"f30f108260120000f30f5986c0050000","Gearbox shift-admission life inputs");
                            ValidateMaterialAnchor(0x4f4461dUL,"f20f1081a0000000660f5ac0f30f5986c8050000","Gearbox native time/coefficient calculation");
                            ValidateMaterialAnchor(0x4f44451UL,"80b94801000000741a","Gearbox lock input");
                            bool observing=MechanicalObservationEnabled();
                            row["gearboxState"]=DecodeGearboxState(data,drive,Read(engine,0x118));
                            row["shiftObservations"]=ShiftObservations(drivetrain);
                            try {
                                ValidateMaterialAnchor(0x4f4cb49UL,"488b4708f30f108048020000","Native engine damage-RPM input");
                                ulong config=BitConverter.ToUInt64(drive,0x10);
                                if(!Ptr(config))throw new InvalidOperationException("Invalid native engine configuration pointer.");
                                byte[] cfg=Read(config,0x268);row["powertrainInputs"]=DecodePowertrainInputs(drive,cfg,data);
                                ((Dictionary<string,object>)row["powertrainInputs"])["identityStableAcrossRead"]=U64(drivetrain+0x10)==config&&SameBytes(cfg,Read(config,0x268));
                            }catch(Exception e){row["powertrainInputError"]=e.Message;}

                        } catch(Exception e){row["gearboxStateError"]=e.Message;}
                    }
                    row["steeringConstraintRoute"]=SteeringConstraintRoute(car,data);
                    try {ValidatePhysicalTyreLayout();row["physicalTyreState"]=DecodePhysicalTyreState(data);}catch(Exception e){row["physicalTyreStateError"]=e.Message;}
                    try {
                        ValidateMaterialAnchor(0x4f072acUL,"488d86f0150000","Native tyre-array base");
                        ValidateMaterialAnchor(0x4efa6a1UL,"4869d878040000","Native tyre-array stride");
                        ValidateMaterialAnchor(0x4f6c108UL,"0f1186d0010000","Native tyre force-frame write");
                        ValidateMaterialAnchor(0x4f67036UL,"80bf4802000000","Actual tyre-force ground-contact branch");
                        row["tyreForceFrames"]=DecodeTyreForceFrames(data);
                        foreach(Dictionary<string,object> wheel in (List<Dictionary<string,object>>)row["tyreForceFrames"]) {
                            try {
                                int offset=0x15f0+(int)wheel["nativeWheelIndex"]*0x478;
                                ulong source=BitConverter.ToUInt64(data,offset+8);
                                wheel["nativeCarBackReference"]=Hex(BitConverter.ToUInt64(data,offset));
                                wheel["transformSourceAddress"]=Hex(source);
                                if(!Ptr(source))throw new InvalidOperationException("Invalid tyre-transform source.");
                                ulong table=U64(source);if(!ImagePtr(table))throw new InvalidOperationException("Unknown tyre-transform source vtable.");
                                ulong getter=U64(table+0x18);if(!ImagePtr(getter))throw new InvalidOperationException("Unknown tyre-transform getter.");
                                wheel["transformGetterRva"]=Hex(getter-imageBase);
                                wheel["transformSourceStable"]=U64(car+(ulong)offset+8)==source&&U64(source)==table;
                            }catch(Exception e){wheel["transformSourceError"]=e.Message;}
                        }

                        row["tyreForceFramesStable"]=SameBytes(data,Read(car,0x2c48));
                    }catch(Exception e){row["tyreForceFrameError"]=e.Message;}

                    foreach(KeyValuePair<string,object> pair in state)row[pair.Key]=pair.Value;
                    bool same=U64(car+8)==link && U64(link)==engine && U64(car+0x1338)==car;
                    if(drive!=null)same=same && U64(car+0x28c0)==holder && U64(holder)==drivetrain && U64(drivetrain+0xf0)==car;
                    row["identityStableAcrossRead"]=same;
                    row["status"]=same?"Captured":"Identity changed; discard this material capture";
                    if(same&&drive!=null)drivingTargets[car]=new ulong[]{drivetrain,link,engine,BitConverter.ToUInt64(drive,0),BitConverter.ToUInt64(drive,0x10)};
                }
                catch(Exception e){row["status"]="Not captured";row["error"]=e.Message;}
            }
            byte[] after=Read(engine+0x308,24);bool stable=true;
            for(int i=0;i<vector.Length;i++)if(vector[i]!=after[i])stable=false;
            if(stable){byte[] again=Read(first,n*8);for(int i=0;i<pointers.Length;i++)if(pointers[i]!=again[i])stable=false;}
            result["vectorStableAcrossRead"]=stable;
            result["status"]=stable?"Read completed; inspect per-car status":"Car vector changed; discard material capture";
        }
        catch(Exception e){result["status"]="Not captured";result["error"]=e.Message;}
        result["readOnly"]=true;
        return result;
    }


    static object FiniteDouble(byte[] data,int offset)
    {
        double v=BitConverter.ToDouble(data,offset);
        return Double.IsNaN(v)||Double.IsInfinity(v)?(object)("non-finite: "+v.ToString()):(object)v;
    }
    public static Dictionary<string,object> DecodeDamageControls(byte[] data,bool native)
    {
        int length=native?0x90:0xb0;
        if(data==null||data.Length!=length)throw new ArgumentException("Damage control block length mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["DamagesEnabled"]=Flag(data,0);
        string[] labels=new string[]{"EngineTorqueMult","EngineMisfireMult","EngineStarterTorqueMult","IntercoolerEffMult","TurboEffMult","RadiatorEffMult","ExhaustTorqueMult","GearboxLifeMult"};
        for(int i=0;i<labels.Length;i++)d[labels[i]]=FiniteFloat(data,4+4*i);
        List<Dictionary<string,object>> wheels=new List<Dictionary<string,object>>();
        for(int i=0;i<4;i++)
        {
            Dictionary<string,object> w=new Dictionary<string,object>();w["index"]=i;
            w["DamperMult"]=native?FiniteFloat(data,0x30+4*i):FiniteDouble(data,0x30+8*i);
            w["WheelGeometryMult"]=native?FiniteFloat(data,0x40+4*i):FiniteDouble(data,0x50+8*i);
            wheels.Add(w);
        }
        d["wheels"]=wheels;
        d["interpretation"]="Recorded damage-control values, NOT measured torque, boost, cooling, toe/camber angles or contact forces. Indices are not assigned UI wheel names by this decoder.";
        return d;
    }
    public static Dictionary<string,object> DecodeGearboxState(byte[] car,byte[] drive,byte[] global)
    {
        if(car==null||car.Length!=0x2c48||drive==null||drive.Length!=0x160||global==null||global.Length!=0x118)
            throw new ArgumentException("Gearbox decoder buffer lengths do not match.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["nativeGearboxLife"]=FiniteFloat(drive,0x120);
        d["configuredGearboxLife"]=FiniteFloat(car,0x5c0);
        d["configuredGrindingCoefficient"]=FiniteFloat(car,0x5c8);
        d["rawGlobalMechanicalDamageRate"]=FiniteFloat(global,0xf0);
        d["nativeTimeStep"]=FiniteDouble(global,0xa0);
        d["gearboxLifeMultiplier"]=FiniteFloat(car,0x1260);
        d["grindingAccumulator"]=FiniteFloat(car,0x12dc);
        d["isGrinding"]=Flag(drive,0x124);d["isGearboxLocked"]=Flag(drive,0x148);
        d["currentGearIndex"]=BitConverter.ToInt32(drive,0x12c);
        d["previousGearIndex"]=BitConverter.ToInt32(drive,0x130);
        d["requestState"]=BitConverter.ToInt32(drive,0x134);
        d["requestedGearIndex"]=BitConverter.ToInt32(drive,0x140);
        d["requestElapsed"]=FiniteFloat(drive,0x138);d["requestDuration"]=FiniteFloat(drive,0x13c);
        d["missedShiftCooldown"]=FiniteFloat(drive,0x144);
        d["localClutch"]=FiniteFloat(drive,0x14c);
        d["damageEnabled"]=Flag(car,0x1240);d["simulationActive"]=Flag(car,0x2c40);
        d["alternativeShiftBranchFlag281d"]=Flag(car,0x281d);
        d["interpretation"]="Native gearbox internals, NOT the component-health percentage. A paused grinding sample is not a history. Raw global rate may stay zero while the local override is active; consult the selected patch and live instruction match. Gear indices are internal, not display labels.";
        return d;
    }

    bool traceLayoutValidated=false;
    void ValidateDamageTraceLayout()
    {
        if(traceLayoutValidated)return;
        ValidateMaterialAnchor(0x5eb3040UL, "80b908010000007442488b81f8000000488b50084c8b4210", "Curve effect apply and type path");
        ValidateMaterialAnchor(0x5eba65cUL, "f30f1082b8000000f30f108a34010000f30f5dc8f30f5fca", "Effect health fraction input");
        ValidateMaterialAnchor(0x4ef9d5fUL, "4c8d4304488d158e188004488b01ff5070488b0f4c8d4308", "Native damage scalar serializer");
        ValidateMaterialAnchor(0x4f06f06UL, "4c8d8640120000488bcf488d15314a7f04e8142effff", "Car damage block location");
        ValidateMaterialAnchor(0x4ef9dfcUL, "488d4330c744242804", "Native per-wheel control layout");
        ValidateMaterialAnchor(0x5e8bd01UL, "4989413049894138498941404989414833c04189490849894950498949584989496049894968", "Unreal double per-wheel layout");
        traceLayoutValidated=true;
    }
    Dictionary<string,object> ModifierComponent(ulong o)
    {
        ValidateDamageTraceLayout();
        Dictionary<string,object> d=new Dictionary<string,object>();
        byte[] block=Read(o+0xd0,0xb0);
        d["effectTargetBlock"]=DecodeDamageControls(block,false);
        d["blockAddress"]=Hex(o+0xd0);
        d["interpretation"]="Unreal-side effect destination. Compare it with each effect binding and with the separate native car block; these non-atomic reads are not proof of physics output.";
        return d;
    }
    string PropertyString(ulong o)
    {
        byte[] h=Read(o+0xc8,16);ulong p=BitConverter.ToUInt64(h,0);
        int n=BitConverter.ToInt32(h,8),capacity=BitConverter.ToInt32(h,12);
        if(n==0&&capacity>=0)return "";
        if(n<1||n>256||capacity<n||capacity>4096||!Ptr(p))throw new InvalidOperationException("Effect property string bounds failed.");
        byte[] b=Read(p,n*2);
        if(b[b.Length-1]!=0||b[b.Length-2]!=0)throw new InvalidOperationException("Effect property string is not terminated.");
        string s=Encoding.Unicode.GetString(b,0,b.Length-2);
        foreach(char c in s)if(Char.IsControl(c)||c=='\0')throw new InvalidOperationException("Effect property name contains a control character.");
        return s;
    }
    Dictionary<string,object> EffectTrace(ulong o,ulong expectedPart)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["readOnly"]=true;
        try
        {
            ValidateDamageTraceLayout();
            byte[] header=Header(o);
            // Only the exact audited native implementation is decoded; a derived implementation
            // can use different binding/storage semantics even when its name looks similar.
            if(ClassName(BitConverter.ToUInt64(header,16))!="CarDamageEffectPhysicsCurveDriven")
                throw new InvalidOperationException("Effect is not the audited exact curve-driven class.");
            ulong table=BitConverter.ToUInt64(header,0);
            if(U64(table+0x2f0)!=imageBase+0x05eb3040UL)
                throw new InvalidOperationException("Effect uses a different value-application routine.");
            byte[] b=Read(o+0x28,0xe8);
            ulong owner=BitConverter.ToUInt64(b,0),component=BitConverter.ToUInt64(b,0x10);
            d["ownerPart"]=Ref(owner);d["ownerMatchesPart"]=owner==expectedPart;
            if(owner!=expectedPart)throw new InvalidOperationException("Effect owner differs from the captured part.");
            d["property"]=PropertyString(o);d["indexMode"]=BitConverter.ToInt32(b,0xb0);
            byte valid=b[0xe0];d["bindingValid"]=valid<=1?(object)(valid==1):(object)("invalid flag: "+valid);
            d["modifierComponent"]=Ref(component);
            ulong target=BitConverter.ToUInt64(b,0xc0),descriptor=BitConverter.ToUInt64(b,0xd0);
            d["boundValueAddress"]=Hex(target);
            if(valid>1)throw new InvalidOperationException("Invalid binding flag.");
            if(valid==1)
            {
                byte[] ch=Header(component);
                if(!Ancestors(BitConverter.ToUInt64(ch,16)).Contains("CarPhysicsModifiersComponent"))
                    throw new InvalidOperationException("Binding component class mismatch.");
                // Refuse to interpret or follow a value destination outside the known component
                // block. A future distinct valid binding remains visible but undecoded.
                ulong block=component+0xd0;
                if(target<block||target>block+0xb0-8)
                    throw new InvalidOperationException("Bound value is outside the audited modifier block.");
                ulong descriptorType=U64(descriptor+8),flags=U64(descriptorType+0x10);
                d["descriptorTypeFlags"]=Hex(flags);d["targetBlockOffset"]=Hex(target-block);
                if((flags&0x100UL)!=0)
                {d["valueType"]="Float32";d["boundValue"]=FiniteFloat(Read(target,4),0);}
                else if((flags&0x100000000UL)!=0)
                {d["valueType"]="Float64";d["boundValue"]=FiniteDouble(Read(target,8),0);}
                else throw new InvalidOperationException("Bound property is not the float/double type used by the audited apply routine.");
                d["modifierValues"]=ModifierComponent(component);
            }
            else d["bindingResult"]="No valid resolved binding at capture; the audited apply routine returns without writing a value.";
            byte[] again=Read(o+0x28,0xe8);
            bool same=BitConverter.ToUInt64(again,0)==owner&&BitConverter.ToUInt64(again,0x10)==component&&
                BitConverter.ToUInt64(again,0xc0)==target&&BitConverter.ToUInt64(again,0xd0)==descriptor&&again[0xe0]==valid;
            byte[] fresh=Read(o,40);
            same=same&&BitConverter.ToInt32(fresh,12)==BitConverter.ToInt32(header,12)&&BitConverter.ToUInt64(fresh,16)==BitConverter.ToUInt64(header,16);
            d["identityStableAcrossRead"]=same;d["status"]=same?"Captured":"Identity changed; discard effect trace";
        }
        catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["interpretation"]="Binding and destination value only. Object existence or a stored multiplier does not prove transfer into the physics solver or the resulting handling.";
        return d;
    }

    Dictionary<string,object> Physics(ulong o)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        ulong settings=U64(o+0x2b8);d["PhysicsSettings"]=Ref(settings);
        if(settings!=0 && Ancestors(BitConverter.ToUInt64(Header(settings),16)).Contains("PhysicsEngineSettings"))
            d["loadedSettingsValues"]=GlobalSettings(settings);
        ulong bridge=U64(o+0x2f8);d["nativeBridgeAddress"]=Hex(bridge);
        if(bridge==0){d["nativeState"]="Not initialized";return d;}
        byte[] bh=Read(bridge,24);
        if(!ImagePtr(BitConverter.ToUInt64(bh,0))) throw new InvalidOperationException("Native bridge vtable does not belong to the audited module.");
        ulong engine=BitConverter.ToUInt64(bh,16);d["nativeEngineAddress"]=Hex(engine);
        if(engine==0){d["nativeState"]="No native engine";return d;}
        // Native settings transfer at RVA 0x0505947e/0x05059638 copies these fields.
        d["nativeValues"]=Floats(engine,
            new int[]{0xa8,0xe4,0xe8,0xec,0xf0,0xf4,0xf8,0xfc},
            new string[]{"puddlesGain","fuelConsumptionRate","tyreConsumptionRate","brakesConsumptionRate","mechanicalDamageRate","compressionDamageRate","punctureProbability","deflationDamageRate"});
        d["nativeMaterialState"]=NativeMaterials(engine);
        d["nativeState"]="Read through the statically traced PhysicsAvatar bridge; gameplay effects not tested by this probe.";
        return d;
    }
    // Narrow, read-only collision/constraint investigation. No native functions are called.
    static string RoutingHex(byte[] b) { return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant(); }
    static bool SameBytes(byte[] a,byte[] b) {
        if(a==null||b==null||a.Length!=b.Length)return false;
        for(int i=0;i<a.Length;i++)if(a[i]!=b[i])return false;
        return true;
    }
    // FProperty extent is ArrayDim(+30) * ElementSize(+34) + Offset_Internal(+44).
    // +38..+3f is PropertyFlags, NOT those two size fields. Verified from game code.
    public static Dictionary<string,object> DescribeCachedRoutingProperty(byte[] property)
    {
        if(property==null||property.Length!=0x48)throw new ArgumentException("Cached FProperty header length mismatch.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["arrayDim"]=BitConverter.ToInt32(property,0x30);
        d["elementSize"]=BitConverter.ToInt32(property,0x34);
        d["propertyFlagsHex"]="0x"+BitConverter.ToUInt64(property,0x38).ToString("x16");
        d["offsetInternal"]=BitConverter.ToInt32(property,0x44);
        d["rawHeaderHex"]=RoutingHex(property);
        return d;
    }
    public static Dictionary<string,object> DecodeCachedRoutingProperty(byte[] property,int storageBytes)
    {
        Dictionary<string,object> d=DescribeCachedRoutingProperty(property);
        int dim=(int)d["arrayDim"],element=(int)d["elementSize"],offset=(int)d["offsetInternal"];
        if(storageBytes<0||storageBytes>4096||dim!=1||element<1||element>4096||offset<0||offset>storageBytes-element)
            throw new ArgumentException("Cached FProperty extent invalid: ArrayDim="+dim+", ElementSize="+element+", Offset_Internal="+offset+", storageBytes="+storageBytes+".");
        return d;
    }
    public static bool IsEmptyRoutingBag(int storageBytes,int descriptorCount,int descriptorCapacity)
    {
        if(storageBytes<0||storageBytes>4096||descriptorCount<0||descriptorCount>128||descriptorCapacity<descriptorCount||descriptorCapacity>4096)
            throw new ArgumentException("Part property-bag extent failed: storageBytes="+storageBytes+", descriptors="+descriptorCount+", capacity="+descriptorCapacity+".");
        if(storageBytes==0&&descriptorCount!=0)throw new ArgumentException("Nonempty descriptor list with zero-byte property storage.");
        return descriptorCount==0;
    }
    public static Dictionary<string,object> DecodeRoutingField(byte[] bag,int offset,int size,int type,int containers)
    {
        if(bag==null||offset<0||size<1||size>4096||offset>bag.Length-size)
            throw new ArgumentException("Routing field lies outside its recorded property bag.");
        if(containers<0||containers>2)throw new ArgumentException("Invalid routing container count.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["offset"]=offset;d["size"]=size;d["typeCode"]=type;d["containerCount"]=containers;
        if(containers==0&&type==5&&size==4){d["value"]=FiniteFloat(bag,offset);d["decodedAs"]="Float32";}
        else if(containers==0&&type==6&&size==8){d["value"]=FiniteDouble(bag,offset);d["decodedAs"]="Float64";}
        else d["decodedAs"]="Unsupported typed field; not treated as zero";
        return d;
    }
    public static List<int> DecodeAllocatedSocketSlots(byte[] header,byte[] allocationBits)
    {
        if(header==null||header.Length!=0x50)throw new ArgumentException("Socket-set header length mismatch.");
        int n=BitConverter.ToInt32(header,8),cap=BitConverter.ToInt32(header,12);
        int bits=BitConverter.ToInt32(header,0x28),maxBits=BitConverter.ToInt32(header,0x2c);
        int free=BitConverter.ToInt32(header,0x34);
        if(n<0||n>512||cap<n||cap>4096||bits!=n||maxBits<bits||maxBits>32768||free<0||free>n)
            throw new ArgumentException("Socket-set allocation bounds failed.");
        if(allocationBits==null||allocationBits.Length!=((bits+31)/32)*4)
            throw new ArgumentException("Socket-set allocation mask length mismatch.");
        List<int> rows=new List<int>();
        for(int i=0;i<bits;i++)if((allocationBits[i/8]&(1<<(i%8)))!=0)rows.Add(i);
        if(rows.Count!=n-free)throw new ArgumentException("Socket-set free-count and allocation-mask disagree.");
        return rows;
    }
    bool routingLayoutValidated=false;
    void ValidateRoutingLayout()
    {
        if(routingLayoutValidated)return;
        ValidateMaterialAnchor(0x5ebb375UL,"4c8b05f4ee6905488d5517488b0cfb4881c138010000e850b56afb","Collision property-bag read");
        ValidateMaterialAnchor(0x155fda7UL,"488b83c000000048638bc800000048c1e1064803c8","Property-bag descriptor stride");
        ValidateMaterialAnchor(0x1566915UL,"488b4830486351444903d0","Property offset and cached descriptor");
        ValidateMaterialAnchor(0x1057590UL,"41b801000000488d15d3b2ba08488d0dcc2c500a","Collision-resistance key initializer");
        ValidateMaterialAnchor(0x4192b83UL,"488d0d762b1f05c7400850000000488908c7400c08000000","Socket struct size and alignment");
        ValidateMaterialAnchor(0x5eaddb7UL,"488d8e380100004c8bc84c8bc3488d5570e813996bfb","Collision-socket property-bag lookup");
        ValidateMaterialAnchor(0x1569a20UL,"8b43300faf4334034344","FProperty ArrayDim/ElementSize/Offset_Internal extent");
        ValidateMaterialAnchor(0x155e3e3UL,"48855338","FProperty flags at +38, not size fields");
        routingLayoutValidated=true;
    }
    // 0.4.0: configured socket names are NOT the live registration cache.
    // This follows the exact cache used by CarDamagePolicyCollisionsSockets.
    public static Dictionary<string,object> DecodePhysicsDamageSelector(byte[] storage,int offset)
    {
        if(storage==null||offset<0||offset>=storage.Length)throw new ArgumentException("Accumulator enum offset is outside its bag.");
        int value=storage[offset];
        string[] names={"EngineTurboAboveThresh","EngineRpmAboveThresh","EngineThrottleRevs","GearboxGrinding"};
        if(value>=names.Length)throw new ArgumentException("Unknown ECarDamagePhysicsAccum value: "+value);
        return new Dictionary<string,object>{{"value",value},{"enumName",names[value]},{"decodedAs","ECarDamagePhysicsAccum (audited UInt8 enum)"}};
    }
    public static Dictionary<string,object> DecodeRegisteredSocketKey(byte[] row)
    {
        if(row==null||row.Length!=0x68)throw new ArgumentException("Registered socket entry must have the audited 0x68-byte stride.");
        ulong component=BitConverter.ToUInt64(row,0);
        if(!Ptr(component))throw new ArgumentException("Registered socket component pointer invalid.");
        return new Dictionary<string,object>{{"componentAddress",component},{"nameIndex",BitConverter.ToUInt32(row,8)},
            {"nameNumber",BitConverter.ToUInt32(row,12)}};
    }
    sealed class RoutingSparseView
    {
        public ulong Address,Data,HeapBits;
        public int Stride;
        public byte[] Header,Mask,Rows;
        public List<int> Slots;
    }
    RoutingSparseView RoutingSparse(ulong address,int stride)
    {
        if(stride!=16&&stride!=24&&stride!=0x68)throw new InvalidOperationException("Unapproved routing sparse stride.");
        RoutingSparseView v=new RoutingSparseView();v.Address=address;v.Stride=stride;v.Header=Read(address,0x50);
        int n=BitConverter.ToInt32(v.Header,8),bits=BitConverter.ToInt32(v.Header,0x28);
        if(n<0||n>512||bits<0||bits>512)throw new InvalidOperationException("Routing sparse extent exceeds bounds.");
        v.Data=BitConverter.ToUInt64(v.Header,0);v.HeapBits=BitConverter.ToUInt64(v.Header,0x20);
        int maskBytes=((bits+31)/32)*4;
        if(v.HeapBits==0){if(maskBytes>16)throw new InvalidOperationException("Sparse inline mask too short.");v.Mask=new byte[maskBytes];Array.Copy(v.Header,0x10,v.Mask,0,maskBytes);}
        else v.Mask=maskBytes==0?new byte[0]:Read(v.HeapBits,maskBytes);
        v.Slots=DecodeAllocatedSocketSlots(v.Header,v.Mask);
        v.Rows=n==0?new byte[0]:Read(v.Data,n*stride);
        return v;
    }
    bool RoutingSparseSame(RoutingSparseView v)
    {
        if(!SameBytes(v.Header,Read(v.Address,0x50)))return false;
        if(v.Rows.Length>0&&!SameBytes(v.Rows,Read(v.Data,v.Rows.Length)))return false;
        if(v.HeapBits!=0&&v.Mask.Length>0&&!SameBytes(v.Mask,Read(v.HeapBits,v.Mask.Length)))return false;
        return true;
    }
    bool registrationLayoutValidated=false;
    void ValidateRegistrationLayout()
    {
        if(registrationLayoutValidated)return;
        // Patched physics/use sites are deliberately not used as immutable anchors.
        ValidateMaterialAnchor(0x05ea4164UL,"488db1c8000000","Socket cache offset");
        ValidateMaterialAnchor(0x05ea431cUL,"4c6bf868488d55c84c0339498b0f4d8b4708488b01ff9010050000","Socket map stride and component/name key");
        ValidateMaterialAnchor(0x05ea4385UL,"498d7710","Registered part set within socket value");
        ValidateMaterialAnchor(0x05ea451aUL,"488b004803c9498b1c24488b0cc8","Registered part pointer-set stride");
        ValidateMaterialAnchor(0x05eab598UL,"f30f5e4e60","Collision influence radius divisor");
        ValidateMaterialAnchor(0x05eab5beUL,"f30f594664f30f114c2428f30f59c9f30f11442430f30f114c242cff90e8020000","Collision magnitude scaling and radius square");
        ValidateMaterialAnchor(0x05ea436cUL,"660f5ac2410f2f460c0f87f2010000","Per-socket distance acceptance");
        ValidateMaterialAnchor(0x05e92055UL,"498b52780f1f80000000004898488d0c404c3904ca488d04ca74378b401083f8ff75","Pending part-amount map layout");
        ValidateMaterialAnchor(0x05e920b9UL,"0f2f0176e4f30f110148","Pending amount keeps maximum");
        ValidateMaterialAnchor(0x05ebbd8cUL,"0f28c685c9742d83e901741e83e901740f83f9017526f30f10876c090000eb1cf30f108768090000eb12f30f108764090000eb08f30f108760090000","Physics accumulator enum switch");
        ulong setType=U64(imageBase+0x0b559378UL);
        if(ObjectName(setType)!="CarDamagesPartsSet"||I32(setType+0x58)!=0x50)
            throw new InvalidOperationException("Registered part-set type/size mismatch.");
        ulong cls=U64(imageBase+0x0b5593f0UL);
        if(ObjectName(cls)!="CarDamagePolicyCollisionsSockets")throw new InvalidOperationException("Socket-policy class singleton mismatch.");
        registrationLayoutValidated=true;
    }
    Dictionary<string,object> RegisteredCollisionSockets(ulong policy)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["readOnly"]=true;d["hasLiveOwner"]=false;
        List<Dictionary<string,object>> rows=new List<Dictionary<string,object>>();d["registrations"]=rows;
        List<RoutingSparseView> views=new List<RoutingSparseView>();
        try {
            ValidateRegistrationLayout();
            byte[] ph=Header(policy);ulong vtable=BitConverter.ToUInt64(ph,0);
            if(U64(vtable+0x2e8)!=imageBase+0x05ea4140UL||U64(vtable+0x2c8)!=imageBase+0x05eadce0UL)
                throw new InvalidOperationException("Socket-policy registration/event implementation differs from audited methods.");
            byte[] config=Read(policy+0x58,0x20); // enabled byte, three floats, cached avatar
            if(config[0]>1)throw new InvalidOperationException("Collision policy enabled flag is not Boolean.");
            ulong owner=U64(policy+0x28),avatar=BitConverter.ToUInt64(config,0x18);
            if(owner==0&&avatar==0){d["status"]="Unbound policy template; not a live cache";return d;}
            d["hasLiveOwner"]=true;
            if(!Ancestors(U64(owner+0x10)).Contains("CarDamageComponent"))throw new InvalidOperationException("Policy owner is not a live damage component.");
            if(!Ancestors(U64(avatar+0x10)).Contains("CarAvatar"))throw new InvalidOperationException("Cached collision avatar identity mismatch.");
            d["ownerDamageComponent"]=Ref(owner);d["cachedCarAvatar"]=Ref(avatar);
            d["nativeCollisionPolicyEnabledFlag"]=config[0]!=0;
            d["MassFlowRate"]=FiniteFloat(config,8);d["DamageRate"]=FiniteFloat(config,12);d["CriticalDamageThreshold"]=FiniteFloat(config,16);
            RoutingSparseView map=RoutingSparse(policy+0xc8,0x68);views.Add(map);
            d["cacheSparseSlots"]=map.Rows.Length/0x68;d["cacheAllocatedKeys"]=map.Slots.Count;
            // Bounded diagnostic configuration, no saves and no unbounded memory scan.
            d["cacheHeaderHex"]=RoutingHex(map.Header);d["cacheAllocationMaskHex"]=RoutingHex(map.Mask);
            int failures=0;
            foreach(int slot in map.Slots) {
                Dictionary<string,object> row=new Dictionary<string,object>();rows.Add(row);row["sparseIndex"]=slot;
                try {
                    byte[] record=new byte[0x68];Array.Copy(map.Rows,slot*0x68,record,0,0x68);
                    Dictionary<string,object> key=DecodeRegisteredSocketKey(record);
                    ulong component=(ulong)key["componentAddress"];
                    byte[] ch=Header(component);
                    if(!Ancestors(BitConverter.ToUInt64(ch,16)).Contains("SceneComponent"))throw new InvalidOperationException("Socket cache key is not a SceneComponent.");
                    row["component"]=Ref(component);row["socketName"]=Name((uint)key["nameIndex"],(uint)key["nameNumber"]);
                    row["rawEntryHex"]=RoutingHex(record);
                    RoutingSparseView parts=RoutingSparse(map.Data+(ulong)(slot*0x68)+0x10,16);views.Add(parts);
                    List<Dictionary<string,object>> linked=new List<Dictionary<string,object>>();row["parts"]=linked;
                    foreach(int partSlot in parts.Slots) {
                        ulong part=BitConverter.ToUInt64(parts.Rows,partSlot*16);byte[] h=Header(part);
                        if(!Ancestors(BitConverter.ToUInt64(h,16)).Contains("CarDamageablePart"))throw new InvalidOperationException("Socket registration points to a non-part object.");
                        Dictionary<string,object> p=Ref(part);p["instanceId"]=Name(U32(part+0x58),U32(part+0x5c));linked.Add(p);
                    }
                    row["partCount"]=linked.Count;
                    row["componentIdentityStable"]=SameBytes(ch,Read(component,40));
                    if(!(bool)row["componentIdentityStable"])throw new InvalidOperationException("Socket component changed during read.");
                    row["status"]="Captured";
                }catch(Exception e){failures++;row["status"]="Not captured";row["error"]=e.Message;}
            }
            // Pending values are cleared by the native update. Zero/empty is NOT no crash.
            Dictionary<string,object> pending=new Dictionary<string,object>();d["pendingDamage"]=pending;
            try {
                RoutingSparseView pv=RoutingSparse(policy+0x78,24);views.Add(pv);
                List<Dictionary<string,object>> pr=new List<Dictionary<string,object>>();pending["parts"]=pr;
                foreach(int slot in pv.Slots){ulong part=BitConverter.ToUInt64(pv.Rows,slot*24);byte[] h=Header(part);
                    if(!Ancestors(BitConverter.ToUInt64(h,16)).Contains("CarDamageablePart"))throw new InvalidOperationException("Pending damage key is not a part.");
                    Dictionary<string,object> p=Ref(part);p["instanceId"]=Name(U32(part+0x58),U32(part+0x5c));p["pendingAmount"]=FiniteFloat(pv.Rows,slot*24+8);pr.Add(p);}
                pending["status"]="Captured";
            }catch(Exception e){pending["status"]="Not captured";pending["error"]=e.Message;failures++;}
            bool stable=SameBytes(ph,Read(policy,40))&&U64(policy+0x28)==owner&&SameBytes(config,Read(policy+0x58,0x20));
            foreach(RoutingSparseView v in views)if(!RoutingSparseSame(v))stable=false;
            d["failedRows"]=failures;d["stableAcrossRead"]=stable;
            d["status"]=stable?(failures==0?"Captured":"Partial registration capture"):"Changed during read; discard registration chapter";
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["meaning"]="Actual cached socket-to-part associations consumed by this collision policy, not merely configured names. Registration does not prove a past impact was inside its influence radius. Pending amounts are transient, not a historical event record.";
        return d;
    }
    Dictionary<string,object> PhysicsDamageAccumulators(ulong avatar)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        try {
            ValidateMaterialAnchor(0x05ebbda2UL,"f30f10876c090000eb1c","GearboxGrinding source on CarAvatar");
            ValidateMaterialAnchor(0x05ebbdacUL,"f30f108768090000eb12f30f108764090000eb08f30f108760090000","Other damage accumulator sources");
            byte[] h=Header(avatar),b=Read(avatar+0x960,16);string[] keys={"EngineTurboAboveThresh","EngineRpmAboveThresh","EngineThrottleRevs","GearboxGrinding"};
            for(int i=0;i<4;i++)d[keys[i]]=FiniteFloat(b,i*4);
            d["identityStableAcrossRead"]=SameBytes(h,Read(avatar,40));d["valuesStableAcrossRead"]=SameBytes(b,Read(avatar+0x960,16));
            d["status"]=(bool)d["identityStableAcrossRead"]&&(bool)d["valuesStableAcrossRead"]?"Captured":"Changed during read; discard accumulator values";
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["meaning"]="Current native damage-policy input accumulators. A zero paused sample is not proof no event occurred earlier; these are not coolant, torque or shift-failure measurements.";
        return d;
    }

    Dictionary<string,object> ReadCollisionSocketSet(ulong address,ulong type)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["address"]=Hex(address);d["valueType"]=Ref(type);
        try {
            if(ObjectName(type)!="CarDamagesCollisionsSockets"||I32(type+0x58)!=0x50)
                throw new InvalidOperationException("Unexpected collision-socket struct identity/size.");
            if(U64(imageBase+0x0b55a058UL)!=type)
                throw new InvalidOperationException("Collision-socket struct differs from the native policy's type.");
            byte[] header=Read(address,0x50);d["rawHeaderHex"]=RoutingHex(header);
            int n=BitConverter.ToInt32(header,8),bits=BitConverter.ToInt32(header,0x28);
            if(n<0||n>512||bits<0||bits>512)throw new InvalidOperationException("Socket-set extent exceeds trace bounds.");
            ulong data=BitConverter.ToUInt64(header,0),heapBits=BitConverter.ToUInt64(header,0x20);
            int maskBytes=((bits+31)/32)*4;
            byte[] mask;
            if(heapBits==0) {
                if(maskBytes>16)throw new InvalidOperationException("Socket inline allocation mask is too small.");
                mask=new byte[maskBytes];Array.Copy(header,0x10,mask,0,maskBytes);
            } else mask=maskBytes==0?new byte[0]:Read(heapBits,maskBytes);
            d["allocationMaskHex"]=RoutingHex(mask);
            List<int> slots=DecodeAllocatedSocketSlots(header,mask);
            byte[] rows=n==0?new byte[0]:Read(data,n*16);
            d["rawSparseEntriesHex"]=RoutingHex(rows);
            List<Dictionary<string,object>> names=new List<Dictionary<string,object>>();
            d["names"]=names;
            foreach(int i in slots) {
                Dictionary<string,object> r=new Dictionary<string,object>();
                r["sparseIndex"]=i;r["socketName"]=Name(BitConverter.ToUInt32(rows,i*16),BitConverter.ToUInt32(rows,i*16+4));
                names.Add(r);
            }
            bool stable=SameBytes(header,Read(address,0x50));
            if(stable&&n>0)stable=SameBytes(rows,Read(data,n*16));
            if(stable&&heapBits!=0&&maskBytes>0)stable=SameBytes(mask,Read(heapBits,maskBytes));
            d["stableAcrossRead"]=stable;d["status"]=stable?"Captured":"Changed during read; discard socket set";
            d["activeSocketCount"]=slots.Count;
        } catch(Exception e) {d["status"]="Not captured";d["error"]=e.Message;}
        d["meaning"]="Configured socket-name set, not contacts observed during a crash. Bounded raw metadata retained only for diagnosis of a rejected layout.";
        return d;
    }
    Dictionary<string,object> CollisionPartRouting(ulong part)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["readOnly"]=true;
        try {
            ValidateRoutingLayout();
            byte[] initial=Read(part+0x138,16);ulong bag=BitConverter.ToUInt64(initial,0),storage=BitConverter.ToUInt64(initial,8);
            d["rawBagReferenceHex"]=RoutingHex(initial);
            if(bag==0){d["status"]="No initialized property bag";return d;}
            byte[] bh=Header(bag);
            if(!Ancestors(BitConverter.ToUInt64(bh,16)).Contains("PropertyBag"))throw new InvalidOperationException("Part property-bag identity mismatch.");
            int size=I32(bag+0x58);byte[] dh=Read(bag+0xc0,16);ulong desc=BitConverter.ToUInt64(dh,0);
            int n=BitConverter.ToInt32(dh,8),cap=BitConverter.ToInt32(dh,12);
            d["schema"]=Ref(bag);d["storageBytes"]=size;d["descriptorCount"]=n;d["rawDescriptorHeaderHex"]=RoutingHex(dh);
            bool empty=IsEmptyRoutingBag(size,n,cap);
            if((n>0&&!Ptr(desc))||(size>0&&!Ptr(storage)))throw new InvalidOperationException("Part property-bag pointer invalid for nonempty storage.");
            byte[] vals=size>0?Read(storage,size):new byte[0],descriptors=n>0?Read(desc,n*64):new byte[0];
            // Max 4096 bytes of this game's part configuration; no saves or unrelated memory.
            d["rawPropertyStorageHex"]=RoutingHex(vals);d["emptyDescriptorList"]=empty;
            List<Dictionary<string,object>> fields=new List<Dictionary<string,object>>();d["fields"]=fields;
            List<string> keys=new List<string>();d["availableFieldNames"]=keys;
            HashSet<string> selected=new HashSet<string>();int failed=0;
            for(int i=0;i<n;i++) {
                int a=i*64;string name=Name(BitConverter.ToUInt32(descriptors,a+0x18),BitConverter.ToUInt32(descriptors,a+0x1c));keys.Add(name);
                if(name!="CollisionsResistance"&&name!="CollisionsSockets"&&name!="WearResistance"&&name!="MechanicalFailureProbability"&&
                   name!="PhysicsDamageAccumMultiplier"&&name!="PhysicsDamageAccum"&&name!="EngineRPMDamageMultiplier"&&
                   name!="EngineTurboDamageMultiplier"&&name!="EngineRevsDamageMultiplier")continue;
                if(!selected.Add(name))throw new InvalidOperationException("Duplicate collision property key.");
                int t=descriptors[a+0x20],containers=descriptors[a+0x23];
                ulong prop=BitConverter.ToUInt64(descriptors,a+0x30),type=BitConverter.ToUInt64(descriptors,a);
                Dictionary<string,object> row=new Dictionary<string,object>();row["name"]=name;fields.Add(row);
                row["typeCode"]=t;row["containerCount"]=containers;row["cachedPropertyAddress"]=Hex(prop);
                byte[] descriptor=new byte[64];Array.Copy(descriptors,a,descriptor,0,64);row["rawDescriptorHex"]=RoutingHex(descriptor);
                try {
                    if(!Ptr(prop))throw new InvalidOperationException("Uninitialized cached FProperty.");
                    byte[] ph=Read(prop,0x48);row["propertyMetadata"]=DescribeCachedRoutingProperty(ph);
                    if(!ImagePtr(BitConverter.ToUInt64(ph,0)))throw new InvalidOperationException("Cached FProperty vtable does not belong to the audited module.");
                    Dictionary<string,object> meta=DecodeCachedRoutingProperty(ph,size);
                    int offset=(int)meta["offsetInternal"],element=(int)meta["elementSize"];
                    foreach(KeyValuePair<string,object> pair in DecodeRoutingField(vals,offset,element,t,containers))row[pair.Key]=pair.Value;
                    if(name=="CollisionsSockets") {
                        if(containers!=0||t!=11||element!=0x50||type==0)throw new InvalidOperationException("Unexpected socket property layout; not decoded as a generic array.");
                        row["valueType"]=Ref(type);Dictionary<string,object> ss=ReadCollisionSocketSet(storage+(ulong)offset,type);row["socketSet"]=ss;
                        if((string)ss["status"]!="Captured")throw new InvalidOperationException("Socket set was not completely decoded or was unstable; inspect its retained metadata.");
                    }
                    if(name=="PhysicsDamageAccum") {
                        if(t!=10||containers!=0||element!=1||ObjectName(type)!="ECarDamagePhysicsAccum")
                            throw new InvalidOperationException("PhysicsDamageAccum enum identity/size differs from audited layout.");
                        ValidateMaterialAnchor(0x05ebbd8cUL,"0f28c685c9742d83e901741e83e901740f83f9017526f30f10876c090000","Physics accumulator enum cases");
                        foreach(KeyValuePair<string,object> pair in DecodePhysicsDamageSelector(vals,offset))row[pair.Key]=pair.Value;
                        row["valueType"]=Ref(type);
                    }
                    if(name!="CollisionsSockets"&&name!="PhysicsDamageAccum"&&(!row.ContainsKey("value")||!(row["value"] is float||row["value"] is double)))
                        throw new InvalidOperationException("Requested component coefficient is absent or not a finite scalar.");
                    if(!SameBytes(ph,Read(prop,0x48)))throw new InvalidOperationException("Cached FProperty changed during read.");
                    row["status"]="Captured";
                }catch(Exception e){failed++;row["status"]="Not decoded";row["error"]=e.Message;}
            }
            bool same=SameBytes(initial,Read(part+0x138,16))&&SameBytes(dh,Read(bag+0xc0,16))&&size==I32(bag+0x58);
            if(same)same=(size==0||SameBytes(vals,Read(storage,size)))&&(n==0||SameBytes(descriptors,Read(desc,n*64)));
            d["stableAcrossRead"]=same;d["failedSelectedFields"]=failed;
            d["status"]=same?(failed==0?"Captured":"Partial: selected fields failed to decode"):"Changed during read; discard routing bag";
            d["missingCollisionKey"]=!selected.Contains("CollisionsResistance");d["missingSocketKey"]=!selected.Contains("CollisionsSockets");
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["interpretation"]="CollisionsResistance is multiplied at the audited caller. This is configuration, not an impact recording. A missing key is not proof of no damage; failed or missing values are not replaced with zero. Bounded game-property bytes are diagnostic, not a full memory dump.";
        return d;
    }

    public static Dictionary<string,object> DecodeConstraintRoute(byte[] suspension,byte[] record,byte[] car,int recordCount,int backendCount,bool backendPresent)
    {
        if(suspension==null||suspension.Length!=0x820||car==null||car.Length!=0x2c48||(record!=null&&record.Length!=0xb0))
            throw new ArgumentException("Steering-route fixture length mismatch.");
        int wheel=BitConverter.ToInt32(suspension,0x10),index=BitConverter.ToInt32(suspension,0x660);
        if(wheel<0||wheel>3||recordCount<0||recordCount>64||backendCount<0||backendCount>64||car[0xb4]>1)
            throw new ArgumentException("Steering-route wheel/count/flag validation failed.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["nativeWheelIndex"]=wheel;d["constraintIndex"]=index;d["constraintRecordCount"]=recordCount;
        d["backendCount"]=backendCount;d["backendEntryPresent"]=backendPresent;d["carEarlyOutFlag_b4"]=car[0xb4]!=0;
        float maximum=BitConverter.ToSingle(car,0x850+wheel*0xe0),severity=BitConverter.ToSingle(car,0x1280+wheel*4);
        d["configuredMaxSteeringOffset"]=FiniteFloat(car,0x850+wheel*0xe0);d["geometryDamageControl"]=FiniteFloat(car,0x1280+wheel*4);
        d["baseAnchorX"]=FiniteDouble(suspension,0x668);d["baseAnchorY"]=FiniteDouble(suspension,0x670);d["baseAnchorZ"]=FiniteDouble(suspension,0x678);
        d["damperMultiplier"]=FiniteFloat(car,0x1270+wheel*4);
        int side=(wheel==0||wheel==2)?1:-1;d["nativeSideSign"]=side;
        bool extent=index>=0&&index<recordCount;
        if((extent&&record==null)||(!extent&&record!=null))throw new ArgumentException("Steering record/index mismatch.");
        bool backend=extent&&index<backendCount&&backendPresent;
        if(record!=null&&extent) {
            double g=BitConverter.ToDouble(record,0x90);d["constraintGeometryComponent90"]=FiniteDouble(record,0x90);
            bool finite=!(Double.IsNaN(g)||Double.IsInfinity(g)||Single.IsNaN(maximum)||Single.IsInfinity(maximum)||Single.IsNaN(severity)||Single.IsInfinity(severity));
            d["calculationInputsFinite"]=finite;
            if(finite) {
                int sign=g>0?1:g<0?-1:0;d["nativeGeometrySign"]=sign;
                float product=severity>0?(float)(maximum*severity):0f;
                double term=(double)product*side*sign;d["calculatedSignedDamageTerm"]=term;
                d["zeroSignedDamageTerm"]=term==0;d["wouldPassRecordedPreconditions"]=car[0xb4]==0&&backend;
            }
        }
        d["routeAtCapture"]=car[0xb4]!=0?"Car flag would stop this routine":!extent?"No eligible steering constraint index":!backend?"No backend constraint entry":"Recorded preconditions permit the call path; execution and output not measured";
        d["interpretation"]="Signed damage term reconstructs the input arithmetic only. Not degrees, measured toe/camber, applied anchor movement, or proof a callback ran. No game function is invoked.";
        return d;
    }
    static double JointFinite(byte[] b,int offset)
    {
        double x=BitConverter.ToDouble(b,offset);
        if(Double.IsNaN(x)||Double.IsInfinity(x)||Math.Abs(x)>1000000.0)
            throw new ArgumentException("Nonfinite or implausible bounded joint value at +"+offset.ToString("x")+".");
        return x;
    }
    public static Dictionary<string,object> DecodeStoredSteeringJoint(byte[] joint,byte[] suspension,ulong expectedVtable)
    {
        if(joint==null||joint.Length!=0xf8||suspension==null||suspension.Length!=0x820)
            throw new ArgumentException("Steering-joint/suspension snapshot length mismatch.");
        if(BitConverter.ToUInt64(joint,0)!=expectedVtable)throw new ArgumentException("Unsupported joint class; anchor layout not assumed.");
        uint flags=BitConverter.ToUInt32(joint,0x30);bool reverse=(flags&2U)!=0;
        int first=reverse?0xc0:0xa0,second=reverse?0xa0:0xc0;
        ulong body1=BitConverter.ToUInt64(joint,reverse?0x58:0x40),body2=BitConverter.ToUInt64(joint,reverse?0x40:0x58);
        if((body1!=0&&!Ptr(body1))||(body2!=0&&!Ptr(body2)))throw new ArgumentException("Invalid joint body identity.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["jointFlagsHex"]="0x"+flags.ToString("x8");d["reverseBodyOrder"]=reverse;
        d["firstBodyAddress"]="0x"+body1.ToString("x");d["secondBodyAddress"]="0x"+body2.ToString("x");
        d["firstAnchorFrame"]=body1==0?"World-space (no first body)":"First-body local";
        d["secondAnchorFrame"]=body2==0?"World-space (no second body)":"Second-body local";
        d["firstAnchorStorageOffset"]=first;d["secondAnchorStorageOffset"]=second;
        string[] axes={"X","Y","Z"};
        for(int i=0;i<3;i++) {
            double current=JointFinite(joint,first+8*i),other=JointFinite(joint,second+8*i),reference=JointFinite(suspension,0x668+8*i);
            d["storedFirstAnchor"+axes[i]]=current;d["storedSecondAnchor"+axes[i]]=other;
            d["suspensionReferenceAnchor"+axes[i]]=reference;d["referenceMinusStoredAnchor"+axes[i]]=reference-current;
        }
        double distance=JointFinite(joint,0xf0);if(distance<0)throw new ArgumentException("Negative joint distance; interpretation rejected.");
        d["storedJointDistance"]=distance;
        byte[] slots=new byte[0x40];Array.Copy(joint,0xa0,slots,0,0x40);d["rawAnchorSlotsHex"]=RoutingHex(slots);
        d["meaning"]="Actual stored joint anchors, not wheel toe/camber or force. Under the audited setter the first-anchor difference includes NORMAL STEERING plus damage and may include other writes. It is not damage-only displacement; native length units are not relabeled.";
        return d;
    }
    public static bool SameSteeringJointMeasurement(byte[] a,byte[] b)
    {
        if(a==null||b==null||a.Length!=0xf8||b.Length!=0xf8)return false;
        int[] offsets={0,0x30,0x40,0x58,0xa0,0xc0,0xf0};int[] sizes={8,4,8,8,24,24,8};
        for(int r=0;r<offsets.Length;r++)for(int i=0;i<sizes[r];i++)if(a[offsets[r]+i]!=b[offsets[r]+i])return false;
        return true;
    }
    public static Dictionary<string,object> DecodeJointBodyFrames(byte[] joint,byte[] first,byte[] second)
    {
        if(joint==null||joint.Length!=0xf8||first==null||second==null||first.Length!=0x1b0||second.Length!=0x1b0)
            throw new ArgumentException("Joint-body frame extent mismatch.");
        double[][] rotations=new double[2][],positions=new double[2][];byte[][] bodies={first,second};
        for(int body=0;body<2;body++) {
            rotations[body]=new double[9];positions[body]=new double[3];
            for(int r=0;r<3;r++) {
                positions[body][r]=JointFinite(bodies[body],0x138+r*8);
                for(int c=0;c<3;c++)rotations[body][r*3+c]=JointFinite(bodies[body],0x158+r*32+c*8);
            }
            double[] a=rotations[body];
            for(int r=0;r<3;r++)for(int c=0;c<3;c++) {
                double dot=0;for(int k=0;k<3;k++)dot+=a[r*3+k]*a[c*3+k];
                if(Math.Abs(dot-(r==c?1.0:0.0))>0.002)throw new ArgumentException("Body rotation is not orthonormal; frame interpretation rejected.");
            }
            double det=a[0]*(a[4]*a[8]-a[5]*a[7])-a[1]*(a[3]*a[8]-a[5]*a[6])+a[2]*(a[3]*a[7]-a[4]*a[6]);
            if(Math.Abs(det-1)>0.003)throw new ArgumentException("Body frame handedness rejected.");
        }
        bool reverse=(BitConverter.ToUInt32(joint,0x30)&2U)!=0;
        int[] anchors=reverse?new int[]{0xc0,0xa0}:new int[]{0xa0,0xc0};double[][] world=new double[2][];
        for(int body=0;body<2;body++) {
            world[body]=new double[3];
            for(int r=0;r<3;r++) {
                world[body][r]=positions[body][r];
                for(int c=0;c<3;c++)world[body][r]+=rotations[body][r*3+c]*JointFinite(joint,anchors[body]+c*8);
            }
        }
        double[] relative=new double[9];
        for(int r=0;r<3;r++)for(int c=0;c<3;c++)for(int k=0;k<3;k++)relative[r*3+c]+=rotations[0][k*3+r]*rotations[1][k*3+c];
        double squared=0;for(int i=0;i<3;i++){double v=world[1][i]-world[0][i];squared+=v*v;}
        double actual=Math.Sqrt(squared),target=JointFinite(joint,0xf0);
        if(target<0||Double.IsNaN(actual)||Double.IsInfinity(actual))throw new ArgumentException("Joint target or calculated distance rejected.");
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["relativeJointBodyYawDegrees"]=Math.Atan2(relative[2],relative[8])*180.0/Math.PI;
        d["relativeJointBodyRollDegrees"]=Math.Atan2(relative[3],relative[4])*180.0/Math.PI;
        d["secondForwardInFirstX"]=relative[2];d["secondForwardInFirstY"]=relative[5];d["secondForwardInFirstZ"]=relative[8];
        d["actualWorldAnchorDistance"]=actual;d["targetWorldAnchorDistance"]=target;d["distanceResidual"]=actual-target;
        d["relativeRotationRowMajor"]=relative;
        d["firstBodyWorldRotationRowMajor"]=rotations[0];d["secondBodyWorldRotationRowMajor"]=rotations[1];
        d["firstBodyWorldPosition"]=positions[0];d["secondBodyWorldPosition"]=positions[1];
        d["meaning"]="Computed from the two actual bodies attached to the audited steering joint. Relative joint-body orientation includes steering and articulation; it is NOT certified wheel toe/camber or tyre force. Distance residual is current anchor separation minus constraint target, not damage alone.";
        return d;
    }
    Dictionary<string,object> ReadSteeringBodyFrames(ulong joint,byte[] bytes)
    {
        Dictionary<string,object> result=new Dictionary<string,object>();result["readOnly"]=true;
        try {
            ValidateMaterialAnchor(0x123e050UL,"4883ec68f20f10a1800100000f28c1f20f598158010000","Native body position/rotation layout");
            bool reverse=(BitConverter.ToUInt32(bytes,0x30)&2U)!=0;
            ulong first=BitConverter.ToUInt64(bytes,reverse?0x58:0x40),second=BitConverter.ToUInt64(bytes,reverse?0x40:0x58);
            if(!Ptr(first)||!Ptr(second)||first==second)throw new InvalidOperationException("Two distinct initialized joint bodies are required.");
            byte[] a=Read(first,0x1b0),b=Read(second,0x1b0);
            foreach(KeyValuePair<string,object> p in DecodeJointBodyFrames(bytes,a,b))result[p.Key]=p.Value;
            bool stable=SameSteeringJointMeasurement(bytes,Read(joint,0xf8))&&SameBytes(a,Read(first,0x1b0))&&SameBytes(b,Read(second,0x1b0));
            result["firstBodyAddress"]=Hex(first);result["secondBodyAddress"]=Hex(second);
            result["stableAcrossRead"]=stable;result["status"]=stable?"Captured":"Body frames changed during capture; discard values";
        }catch(Exception e){result["status"]="Not captured";result["error"]=e.Message;}
        return result;
    }

    // Pure read-only report arithmetic; does not change simulation state.
    public static double EffectiveSignedSteeringTerm(double term,bool boosted)
    {
        if(!boosted||Double.IsNaN(term)||Double.IsInfinity(term))return term;
        float magnitude=(float)Math.Abs(term);
        if(magnitude<=0||magnitude>=0.02f)return term;
        float scaled=Math.Min(magnitude*3.0f,0.02f);
        return term<0?-(double)scaled:(double)scaled;
    }
    public static double EffectiveCustomSteeringTerm(double term,bool boosted,float gain,float limit)
    {
        if(Single.IsNaN(gain)||Single.IsInfinity(gain)||gain<0||gain>6||Single.IsNaN(limit)||Single.IsInfinity(limit)||limit<0||limit>0.05f)throw new ArgumentException("Invalid custom geometry number");
        if(!boosted||Double.IsNaN(term)||Double.IsInfinity(term))return term;
        float magnitude=(float)Math.Abs(term);if(magnitude<=0||magnitude>=limit)return term;
        float scaled=Math.Min(magnitude*gain,limit);return term<0?-(double)scaled:(double)scaled;
    }
    void AddEffectiveGeometryInputs(Dictionary<string,object> state,bool boosted)
    {
        float gain=3.0f,limit=0.02f;
        if(boosted){byte[] tuning=Read(imageBase+0x00d22410UL,8);gain=BitConverter.ToSingle(tuning,0);limit=BitConverter.ToSingle(tuning,4);if(Single.IsNaN(gain)||Single.IsInfinity(gain)||gain<0||gain>6||Single.IsNaN(limit)||Single.IsInfinity(limit)||limit<0||limit>0.05f)throw new InvalidOperationException("Invalid deformation tuning values.");}
        state["nativeDeformationBoostEnabled"]=boosted;
        List<Dictionary<string,object>> wheels=(List<Dictionary<string,object>>)state["wheels"];
        foreach(Dictionary<string,object> wheel in wheels) {
            wheel["nativeDeformationGain"]=boosted?(double)gain:1.0;wheel["nativeDeformationLimit"]=boosted?(double)limit:0.0;
            wheel["effectiveUnsignedDamageOffsetTerm"]=(bool)wheel["productInputsValid"]?EffectiveCustomSteeringTerm(Convert.ToDouble(wheel["unsignedDamageOffsetTerm"]),boosted&&Convert.ToDouble(wheel["unsignedDamageOffsetTerm"])>0,gain,limit):(object)null;
        }
    }
    // Read the audited instruction bytes to label this snapshot accurately.
    // The collector subsequently verifies the complete selected instruction table.
    bool GeometryBoostEnabled()
    {
        byte[] bytes=Read(imageBase+0x04f3573fUL,15);
        if(RoutingHex(bytes)=="f30f5cc1f30f59c5f30f58c10f5ac8")return false;
        if(RoutingHex(bytes)=="e86cccdefb90909090909090909090")return true;
        throw new InvalidOperationException("Unknown native deformation instructions; optional measurement rejected.");
    }

    Dictionary<string,object> ReadStoredSteeringJoint(ulong backend,byte[] suspension)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["readOnly"]=true;d["backendAddress"]=Hex(backend);
        try {
            ValidateMaterialAnchor(0x4f78975UL,"4c8bf1488b494833d2","Steering backend joint at +48");
            ValidateMaterialAnchor(0x123f3b0UL,"83fa01760333c0c3f64130027413","Joint body-order selection");
            ValidateMaterialAnchor(0x1243176UL,"f6413002488bd97431488b4958488d83c0000000","First anchor reverse branch");
            ValidateMaterialAnchor(0x12431b0UL,"488b4940488d83a0000000","First anchor normal branch");
            ValidateMaterialAnchor(0x12432a0UL,"f20f1189f0000000c3","Joint distance storage");
            ValidateMaterialAnchor(0x1242a17UL,"488d05726f690933f6488d8ba0000000488903","DBall joint identity and anchor layout");
            ulong vt=U64(backend);d["backendVtableRva"]=ImagePtr(vt)?Hex(vt-imageBase):"outside module";
            if(vt!=imageBase+0x097054e8UL||U64(vt+8)!=imageBase+0x04f77c00UL||U64(vt+0xc0)!=imageBase+0x04f78950UL)
                throw new InvalidOperationException("Backend differs from audited steering setter; no joint layout assumed.");
            ulong joint=U64(backend+0x48);d["jointAddress"]=Hex(joint);
            byte[] bytes=Read(joint,0xf8);ulong jvt=BitConverter.ToUInt64(bytes,0);
            d["jointVtableRva"]=ImagePtr(jvt)?Hex(jvt-imageBase):"outside module";
            foreach(KeyValuePair<string,object> pair in DecodeStoredSteeringJoint(bytes,suspension,imageBase+0x0a8d9990UL))d[pair.Key]=pair.Value;
            d["bodyFrames"]=ReadSteeringBodyFrames(joint,bytes);
            bool stable=SameSteeringJointMeasurement(bytes,Read(joint,0xf8))&&U64(backend+0x48)==joint&&U64(backend)==vt;
            d["stableAcrossRead"]=stable;d["status"]=stable?"Captured":"Joint changed during read; discard measurement";
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        return d;
    }
    int RouteVectorCount(byte[] bytes,int offset,int stride,int maximum,string label)
    {
        ulong begin=BitConverter.ToUInt64(bytes,offset),end=BitConverter.ToUInt64(bytes,offset+8),capacity=BitConverter.ToUInt64(bytes,offset+16);
        if(end<begin||capacity<end||(end-begin)%(ulong)stride!=0||(capacity-begin)%(ulong)stride!=0||
            (end-begin)/(ulong)stride>(ulong)maximum||(capacity-begin)/(ulong)stride>4096UL||
            (begin!=0&&!Ptr(begin))||(begin==0&&(end!=0||capacity!=0)))
            throw new InvalidOperationException(label+" vector bounds failed.");
        return (int)((end-begin)/(ulong)stride);
    }
    Dictionary<string,object> SteeringConstraintRoute(ulong car,byte[] carData)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();d["readOnly"]=true;
        try {
            ValidateMaterialAnchor(0x4f07233UL,"488b86e81500004c8d4d18488d15c3477f04","Native suspension collection");
            ValidateMaterialAnchor(0x4f2f98fUL,"488d05a2057d04488bf1488901","Custom-suspension vtable identity");
            ValidateMaterialAnchor(0x4f3563dUL,"4863836006000085c00f88be0100004c8b9300030000","Steering constraint index and record vector");
            ValidateMaterialAnchor(0x4f35766UL,"488b8b08080000488b8310080000482bc148c1f803493bc0","Steering backend vector");
            ValidateMaterialAnchor(0x4f35735UL,"f3420f10840a50080000","Native damage maximum input");
            bool boosted=GeometryBoostEnabled();
            ulong holder=BitConverter.ToUInt64(carData,0x15e8);byte[] h=Read(holder,24);int n=RouteVectorCount(h,0,8,4,"Car suspension");
            if(n!=4)throw new InvalidOperationException("Expected four native suspension entries.");
            ulong begin=BitConverter.ToUInt64(h,0);byte[] ptrs=Read(begin,n*8);
            List<Dictionary<string,object>> wheels=new List<Dictionary<string,object>>();d["wheels"]=wheels;
            HashSet<int> indices=new HashSet<int>();
            for(int i=0;i<n;i++) {
                Dictionary<string,object> row=new Dictionary<string,object>();row["collectionIndex"]=i;wheels.Add(row);
                try {
                    ulong s=BitConverter.ToUInt64(ptrs,i*8);byte[] bytes=Read(s,0x820);ulong vt=BitConverter.ToUInt64(bytes,0);
                    row["suspensionAddress"]=Hex(s);row["vtableRva"]=ImagePtr(vt)?Hex(vt-imageBase):"outside module";
                    if(vt!=imageBase+0x096fff38UL||U64(vt+0xa0)!=imageBase+0x04f355f0UL||BitConverter.ToUInt64(bytes,8)!=car)
                        throw new InvalidOperationException("Suspension class/owner differs from audited implementation.");
                    int w=BitConverter.ToInt32(bytes,0x10);if(w<0||w>3||!indices.Add(w))throw new InvalidOperationException("Suspension wheel identity invalid or duplicated.");
                    int count=RouteVectorCount(bytes,0x300,0xb0,64,"Constraint record"),backCount=RouteVectorCount(bytes,0x808,8,64,"Constraint backend");
                    int index=BitConverter.ToInt32(bytes,0x660);byte[] record=null;ulong recAddress=0,backAddress=0,backend=0;
                    if(index>=0&&index<count) {recAddress=BitConverter.ToUInt64(bytes,0x300)+(ulong)(index*0xb0);record=Read(recAddress,0xb0);}
                    if(index>=0&&index<backCount) {
                        backAddress=BitConverter.ToUInt64(bytes,0x808)+(ulong)(index*8);backend=U64(backAddress);
                        if(backend!=0) {ulong bv=U64(backend);if(!ImagePtr(bv))throw new InvalidOperationException("Backend entry vtable does not belong to the supported module.");row["backendVtableRva"]=Hex(bv-imageBase);row["backendGetterRva"]=ImagePtr(U64(bv+8))?Hex(U64(bv+8)-imageBase):"outside module";}
                    }
                    foreach(KeyValuePair<string,object> pair in DecodeConstraintRoute(bytes,record,carData,count,backCount,backend!=0))row[pair.Key]=pair.Value;
                    row["deformationBoostEnabled"]=boosted;row["effectiveSignedDamageTerm"]=row["calculatedSignedDamageTerm"]==null?null:(object)EffectiveSignedSteeringTerm(Convert.ToDouble(row["calculatedSignedDamageTerm"]),boosted&&Convert.ToDouble(row["configuredMaxSteeringOffset"])>0);
                    row["backendAddress"]=Hex(backend);
                    if(backend!=0)row["storedJointAnchors"]=ReadStoredSteeringJoint(backend,bytes);
                    byte[] again=Read(s,0x820);bool same=SameBytes(bytes,again);
                    if(record!=null)same=same&&SameBytes(record,Read(recAddress,0xb0));
                    if(backAddress!=0)same=same&&U64(backAddress)==backend;
                    row["stableAcrossRead"]=same;row["status"]=same?"Captured":"Suspension changed during read; discard this route";
                }catch(Exception e){row["status"]="Not captured";row["error"]=e.Message;}
            }
            bool stable=U64(car+0x15e8)==holder&&SameBytes(h,Read(holder,24))&&SameBytes(ptrs,Read(begin,n*8));
            d["vectorStableAcrossRead"]=stable;d["status"]=stable?"Read completed; inspect each wheel status":"Suspension collection changed; discard chapter";
        }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        return d;
    }

    Dictionary<string,object> DamagePart(ulong o)
    {
        // Native UHT descriptors + collision life setter, exact audited build.
        // A fresh narrow read reduces cross-field skew but is not atomic.
        byte[] id=Read(o+0x58,8);
        byte[] data=Read(o+0xb8,0xa0);
        float maximum=BitConverter.ToSingle(data,0), life=BitConverter.ToSingle(data,0x7c);
        int state=BitConverter.ToInt32(data,0x78);
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["instanceId"]=Name(BitConverter.ToUInt32(id,0),BitConverter.ToUInt32(id,4));
        d["outerObject"]=Ref(U64(o+0x20));
        bool valid=!Single.IsNaN(maximum)&&!Single.IsInfinity(maximum)&&!Single.IsNaN(life)&&!Single.IsInfinity(life)&&maximum>0&&life>=0&&life<=maximum*1.001f;
        d["maxLifePoints"]=Single.IsNaN(maximum)||Single.IsInfinity(maximum)?(object)maximum.ToString():(object)maximum;
        d["lifePoints"]=Single.IsNaN(life)||Single.IsInfinity(life)?(object)life.ToString():(object)life;
        d["lifePercentage"]=valid?(object)(100.0*(double)life/(double)maximum):null;
        d["lifeRangeValid"]=valid; d["stateIndex"]=state;
        if(!valid)d["warning"]="Uninitialized or inconsistent life range; no percentage inferred.";
        ulong stateArray=BitConverter.ToUInt64(data,8);
        int stateCount=BitConverter.ToInt32(data,16), stateCapacity=BitConverter.ToInt32(data,20);
        if(stateCount>=0 && stateCount<=64 && stateCapacity>=stateCount && (stateCount==0||Ptr(stateArray)))
        {
            List<Dictionary<string,object>> entries=new List<Dictionary<string,object>>();
            if(stateCount>0)
            {
                byte[] states=Read(stateArray,stateCount*32);
                for(int i=0;i<stateCount;i++)
                {
                    Dictionary<string,object> row=new Dictionary<string,object>();
                    row["index"]=i;row["nativeStateTypeByte"]=states[i*32+8];
                    float fraction=BitConverter.ToSingle(states,i*32+12);
                    row["lifeFraction"]=Single.IsNaN(fraction)||Single.IsInfinity(fraction)?(object)fraction.ToString():(object)fraction;
                    entries.Add(row);
                }
            }
            d["authoredStateThresholds"]=entries;
        }
        else d["thresholdReadWarning"]="State-array bounds failed; skipped.";
        ulong effectArray=BitConverter.ToUInt64(data,0x90);
        int effectCount=BitConverter.ToInt32(data,0x98), effectCapacity=BitConverter.ToInt32(data,0x9c);
        d["effectCount"]=effectCount;
        if(effectCount>=0&&effectCount<=128&&effectCapacity>=effectCount&&(effectCount==0||Ptr(effectArray)))
        {
            List<Dictionary<string,object>> effects=new List<Dictionary<string,object>>();
            if(effectCount>0)
            {
                byte[] pointers=Read(effectArray,effectCount*8);
                for(int i=0;i<effectCount;i++) {
                    ulong effect=BitConverter.ToUInt64(pointers,i*8);Dictionary<string,object> r=Ref(effect);
                    if(r.ContainsKey("class")&&(string)r["class"]=="CarDamageEffectPhysicsCurveDriven")r["damageTrace"]=EffectTrace(effect,o);
                    effects.Add(r);
                }
                byte[] again=Read(o+0x148,12);bool same=BitConverter.ToUInt64(again,0)==effectArray&&BitConverter.ToInt32(again,8)==effectCount;
                if(same){byte[] second=Read(effectArray,effectCount*8);for(int j=0;j<second.Length;j++)if(second[j]!=pointers[j])same=false;}
                d["effectArrayStableAcrossRead"]=same;
            }
            d["activeEffects"]=effects;
        }
        else d["effectReadWarning"]="Effect-array bounds failed; skipped.";
        d["collisionRouting"]=CollisionPartRouting(o);
        d["interpretation"]="Component life and authored state/effect identities, NOT a direct measurement of cooling, alignment, force, or rendered deformation.";
        return d;
    }
    Dictionary<string,object> RuntimeDamageParts(ulong owner)
    {
        Dictionary<string,object> d=new Dictionary<string,object>();
        d["readOnly"]=true;d["status"]="Not captured";d["identityStable"]=false;
        d["candidateReady"]=false;d["engineMatches"]=0;d["gearboxMatches"]=0;
        d["partCount"]=0;
        try {
            ValidateMaterialAnchor(0x5eaa154UL,"8b8620010000","Runtime damage-part count");
            ValidateMaterialAnchor(0x5eaa188UL,"488b8e18010000488904d1","Runtime damage-part array");
            byte[] header=Read(owner+0x118,16);
            ulong array=BitConverter.ToUInt64(header,0);
            int n=BitConverter.ToInt32(header,8),cap=BitConverter.ToInt32(header,12);
            if(n<0||n>128||cap<n||cap>4096)throw new InvalidOperationException("Runtime part-array bounds failed.");
            d["partCount"]=n;
            if(n==0){d["status"]="No runtime parts";return d;}
            if(!Ptr(array)||(array&7UL)!=0)throw new InvalidOperationException("Runtime part-array pointer invalid.");
            byte[] pointers=Read(array,n*8);int engines=0,gears=0;
            ulong engineClass=0,gearClass=0;
            List<Dictionary<string,object>> parts=new List<Dictionary<string,object>>();
            d["parts"]=parts;
            for(int i=0;i<n;i++) {
                ulong part=BitConverter.ToUInt64(pointers,i*8);
                if(!Ptr(part)||(part&7UL)!=0)throw new InvalidOperationException("Runtime part pointer invalid.");
                byte[] h=Header(part);ulong type=BitConverter.ToUInt64(h,16);
                if(U64(part+0x20)!=owner||!Ancestors(type).Contains("CarDamageablePart"))
                    throw new InvalidOperationException("Runtime part owner/class mismatch.");
                string name=Name(U32(part+0x58),U32(part+0x5c));
                Dictionary<string,object> row=Ref(part);row["instanceId"]=name;parts.Add(row);
                if(String.Equals(name,"Engine",StringComparison.OrdinalIgnoreCase)){engines++;engineClass=type;}
                if(String.Equals(name,"GearBox",StringComparison.OrdinalIgnoreCase)){gears++;gearClass=type;}
            }
            byte[] header2=Read(owner+0x118,16),pointers2=Read(array,n*8);
            bool stable=true;
            for(int i=0;i<header.Length;i++)if(header[i]!=header2[i])stable=false;
            for(int i=0;i<pointers.Length;i++)if(pointers[i]!=pointers2[i])stable=false;
            for(int i=0;i<n;i++)if(U64(BitConverter.ToUInt64(pointers,i*8)+0x20)!=owner)stable=false;
            d["engineMatches"]=engines;d["gearboxMatches"]=gears;
            d["sameClass"]=engineClass!=0&&engineClass==gearClass;
            d["identityStable"]=stable;
            d["candidateReady"]=stable&&engines==1&&gears==1&&engineClass==gearClass;
            d["status"]=stable?"Captured":"Array changed; discard inventory";
        } catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
        d["meaning"]="Live component part inventory used by optional gearbox impact transfer. Readiness is not proof an impact executed or a shift failed. Configuration-only templates have no runtime inventory.";
        return d;
    }

    Dictionary<string,object> DamageComponent(ulong o)
    {
        Dictionary<string,object> d=Floats(o,new int[]{0x148,0x14c,0x150},
            new string[]{"DamageCollisionsMultiplier","DamageWearMultiplier","DamageMechanicalFailuresMultiplier"});
        d["partCount"]=I32(o+0x120);d["policyCount"]=I32(o+0x140);
        d["runtimePartInventory"]=RuntimeDamageParts(o);
        d["interpretation"]="Stored native properties. The v0.5.0 EXE collision multiplier acts at use and does not change this property value. Zero remains zero.";
        return d;
    }
    // Pure decoder for already collected game-physics byte arrays. No process access.
    public static List<Dictionary<string,object>> DecodePhysicalTyreState(byte[] car)
    {
        if(car==null||car.Length!=0x2c48)throw new ArgumentException("Physical tyre-state extent mismatch.");
        List<Dictionary<string,object>> result=new List<Dictionary<string,object>>();
        for(int w=0;w<4;w++) {
            int tyre=0x15f0+w*0x478,state=tyre+0x1d0,force=state+0x120;
            Dictionary<string,object> d=new Dictionary<string,object>();result.Add(d);d["nativeWheelIndex"]=w;
            try {
                if(BitConverter.ToInt32(car,tyre+0x18)!=w)throw new ArgumentException("Physical tyre index mismatch.");
                d["groundContact"]=Flag(car,state+0x78);
                d["normalLoad"]=FiniteFloat(car,state+0x108);
                int[] offsets={0x18,0x1c,0x20,0x24,0x28,0x58,0x5c,0x60,0x64,0x68};
                string[] names={"slidingVelocityY","slidingVelocityX","camberRAD","slipAngleRAD","slipRatio","fy","fx","mz","corneringK","longitudinalK"};
                for(int i=0;i<offsets.Length;i++)d[names[i]]=FiniteFloat(car,force+offsets[i]);
                d["worldDriveForceX"]=FiniteDouble(car,state+0x1a8);
                d["worldDriveForceY"]=FiniteDouble(car,state+0x1b0);
                d["worldDriveForceZ"]=FiniteDouble(car,state+0x1b8);
                d["status"]="Captured";
            }catch(Exception e){d["status"]="Not captured";d["error"]=e.Message;}
            d["meaning"]="Native TyreState.force outputs and final driveForce vector, not older lat/lon fields. Native units and axes retained. Includes current steering, motion, contact and camber; not damage alone.";
        }
        return result;
    }
    void ValidatePhysicalTyreLayout()
    {
        ValidateMaterialAnchor(0x4f4a398UL,"488b01f30f108028130000","Native steer-command source");
        ValidateMaterialAnchor(0x4f6afa4UL,"488d8ed0010000","TyreState containing offset");
        ValidateMaterialAnchor(0x4f6b5d8UL,"488d8e20010000","Native tyre force-state offset");
        ValidateMaterialAnchor(0x4f6b1c7UL,"ff5070488b0b4c8d4758","Native fy serialized offset");
        ValidateMaterialAnchor(0x4f6b641UL,"488d9ea8010000","Final tyre drive-force vector");
    }
    // Optional read-only driving samples using this reader's existing VM_READ handle.
    // The initial snapshot must approve the car; no writes, injection, or game calls.
    readonly Dictionary<ulong,ulong[]> drivingTargets=new Dictionary<ulong,ulong[]>();
    public Dictionary<string,object> CaptureDrivingSample(ulong car,ulong drive)
    {
        ulong[] target;
        if(!drivingTargets.TryGetValue(car,out target)||target[0]!=drive)
            throw new InvalidOperationException("Driving target was not approved by the initial full snapshot.");
        System.Diagnostics.Stopwatch clock=System.Diagnostics.Stopwatch.StartNew();
        byte[] body=Read(car,0x2c48),gear=Read(drive,0x160);
        ulong holder=BitConverter.ToUInt64(body,0x28c0),link=BitConverter.ToUInt64(body,8);
        if(link!=target[1]||U64(link)!=target[2]||BitConverter.ToUInt64(body,0x1338)!=car||
           !Ptr(holder)||U64(holder)!=drive||BitConverter.ToUInt64(gear,0xf0)!=car||
           BitConverter.ToUInt64(gear,0)!=target[3]||BitConverter.ToUInt64(gear,0x10)!=target[4])
            throw new InvalidOperationException("Car identity changed; recording stopped rather than following a new car.");
        Dictionary<string,object> sample=new Dictionary<string,object>();
        sample["utc"]=DateTime.UtcNow.ToString("o");sample["carAddress"]=Hex(car);sample["drivetrainAddress"]=Hex(drive);
        byte[] controls=new byte[0x90];Array.Copy(body,0x1240,controls,0,controls.Length);
        sample["damageControls"]=DecodeDamageControls(controls,true);
        sample["gearbox"]=DecodeGearboxState(body,gear,Read(target[2],0x118));
        sample["powertrain"]=DecodePowertrainInputs(gear,Read(target[4],0x268),body);
        sample["shiftObservations"]=ShiftObservations(drive);
        sample["gameplayExtensions"]=GameplayObservation(car,drive,body,gear);
        sample["materials"]=DecodeNativeMaterialState(body,gear);
        sample["damageWarnings"]=ReadWarningEvidence(car);
        sample["engineWearAccounting"]=EngineWearAuditObservation(car);
        sample["engineWearInputs"]=ReadEngineWearEvidence(car);
        sample["geometryDamageInputs"]=DecodeGeometryDamageInputs(body);
        sample["physicalTyreState"]=DecodePhysicalTyreState(body);
        List<Dictionary<string,object>> tyres=DecodeTyreForceFrames(body);
        foreach(Dictionary<string,object> t in tyres){t.Remove("boundedTyreStateHex");t.Remove("meaning");}
        sample["tyreFrames"]=tyres;
        sample["steering"]=SteeringConstraintRoute(car,body);
        bool same=U64(car+8)==link&&U64(link)==target[2]&&U64(car+0x28c0)==holder&&U64(holder)==drive&&U64(drive+0xf0)==car;
        if(!same)throw new InvalidOperationException("Car identity changed during the sample; recording stopped.");
        sample["identityStableAcrossRead"]=true;
        sample["readSpanMilliseconds"]=clock.Elapsed.TotalMilliseconds;
        sample["cumulativeBytesRead"]=bytesReadTotal;
        sample["nonAtomicSample"]=true;
        sample["readOnly"]=true;
        return sample;
    }

    readonly Dictionary<ulong,Tuple<ulong[],int[]>> engineWearTargets=new Dictionary<ulong,Tuple<ulong[],int[]>>();
    float engineUseWearScale=1.0f;
    public static Dictionary<string,object> DecodeEngineWearSources(byte[] accumulators,byte[] coefficients,float ownerMultiplier,float useScale) {
        if(accumulators==null||accumulators.Length!=16||coefficients==null||coefficients.Length!=12)throw new ArgumentException("Engine wear source extent mismatch.");
        var d=new Dictionary<string,object>();var a=new float[4];var c=new float[3];
        for(int i=0;i<4;i++){a[i]=BitConverter.ToSingle(accumulators,i*4);if(Single.IsNaN(a[i])||Single.IsInfinity(a[i])||a[i]<0)throw new ArgumentException("Invalid native wear input.");}
        for(int i=0;i<3;i++){c[i]=BitConverter.ToSingle(coefficients,i*4);if(Single.IsNaN(c[i])||Single.IsInfinity(c[i])||c[i]<0)throw new ArgumentException("Invalid authored wear coefficient.");}
        if(Single.IsNaN(ownerMultiplier)||Single.IsInfinity(ownerMultiplier)||ownerMultiplier<0||ownerMultiplier>1000||Single.IsNaN(useScale)||Single.IsInfinity(useScale)||useScale<0||useScale>2)throw new ArgumentException("Invalid engine wear scale.");
        d["EngineTurboAboveThresh"]=a[0];d["EngineRpmAboveThresh"]=a[1];d["EngineThrottleRevs"]=a[2];d["GearboxGrinding"]=a[3];
        d["EngineRevsDamageMultiplier"]=c[0];d["EngineRPMDamageMultiplier"]=c[1];d["EngineTurboDamageMultiplier"]=c[2];d["OwnerDamageWearMultiplier"]=ownerMultiplier;d["RoutineEngineUseScale"]=useScale;
        d["estimatedUseTermForObservedInput"]=(double)a[2]*c[0]*ownerMultiplier*useScale;
        d["estimatedOverRpmTermForObservedInput"]=(double)a[1]*c[1]*ownerMultiplier;
        d["estimatedTurboTermForObservedInput"]=(double)a[0]*c[2]*9.86923259915784e-6*ownerMultiplier;
        d["meaning"]="Instantaneous policy inputs and authored coefficients; NOT cumulative damage or per-second rates. Do not sum repeated sampled accumulator values. Other policies, health floors, float rounding and unobserved updates remain separate.";
        return d;
    }
    void RegisterEngineWearTarget(ulong car,ulong address,ulong owner,ulong actor,Dictionary<string,object> part) {
        try {
            var routing=(Dictionary<string,object>)part["collisionRouting"];
            if((string)routing["status"]!="Captured"||!(bool)routing["stableAcrossRead"])return;
            var offsets=new int[]{-1,-1,-1};string[] names={"EngineRevsDamageMultiplier","EngineRPMDamageMultiplier","EngineTurboDamageMultiplier"};
            foreach(var field in (List<Dictionary<string,object>>)routing["fields"]){if((string)field["status"]!="Captured"||!field.ContainsKey("value"))continue;for(int i=0;i<3;i++)if((string)field["name"]==names[i]&&(string)field["decodedAs"]=="Float32")offsets[i]=Convert.ToInt32(field["offset"]);}
            int size=Convert.ToInt32(routing["storageBytes"]);foreach(int offset in offsets)if(offset<0||offset>size-4||size>4096)return;
            byte[] bag=Read(address+0x138,16);ulong schema=BitConverter.ToUInt64(bag,0),storage=BitConverter.ToUInt64(bag,8);if(!Ptr(schema)||!Ptr(storage))return;
            if(engineWearTargets.ContainsKey(car)){engineWearTargets.Remove(car);return;}
            engineWearTargets.Add(car,Tuple.Create(new ulong[]{address,owner,actor,U64(address+0x10),U32(address+12),schema,storage},offsets));
        }catch(Exception e){Warn("Engine wear metadata unavailable: "+e.Message);}
    }
    Dictionary<string,object> ReadEngineWearEvidence(ulong car) {
        var result=new Dictionary<string,object>();Tuple<ulong[],int[]> target;
        if(!engineWearTargets.TryGetValue(car,out target)){result["status"]="Not captured: initial engine policy metadata unavailable";return result;}
        try {
            ulong[] t=target.Item1;int[] offsets=target.Item2;
            if(U64(t[0]+0x10)!=t[3]||U32(t[0]+12)!=t[4]||U64(t[0]+0x20)!=t[1]||U64(t[1]+0x20)!=t[2]||U64(t[2]+0x580)!=car||U64(t[0]+0x138)!=t[5]||U64(t[0]+0x140)!=t[6])throw new InvalidOperationException("Engine wear source identity changed.");
            ValidateMaterialAnchor(0x5ebb743UL,"498b4728f30f104c2430","Engine owner wear multiplier and routine-use coefficient");
            ValidateMaterialAnchor(0x5ebb756UL,"f30f59d7f30f59542420f30f58d0f30f58d1f30f59904c010000","Separate turbo, overspeed and use terms before health update");
            byte[] a=Read(t[2]+0x960,16),c=new byte[12],owner=Read(t[1]+0x14c,4);
            for(int i=0;i<3;i++)Array.Copy(Read(t[6]+(ulong)offsets[i],4),0,c,i*4,4);
            result=DecodeEngineWearSources(a,c,BitConverter.ToSingle(owner,0),engineUseWearScale);
            bool stable=SameBytes(a,Read(t[2]+0x960,16))&&SameBytes(owner,Read(t[1]+0x14c,4));
            for(int i=0;i<3;i++){byte[] next=Read(t[6]+(ulong)offsets[i],4);for(int j=0;j<4;j++)if(next[j]!=c[i*4+j])stable=false;}
            stable=stable&&U64(t[0]+0x140)==t[6]&&U64(t[2]+0x580)==car&&U64(t[0]+0x10)==t[3]&&U32(t[0]+12)==t[4];
            result["stableAcrossRead"]=stable;result["status"]=stable?"Captured":"Changed during read; do not use this source estimate";
        }catch(Exception e){result["status"]="Not captured";result["error"]=e.Message;}
        return result;
    }

    readonly Dictionary<ulong,List<ulong[]>> warningParts=new Dictionary<ulong,List<ulong[]>>();
    readonly Dictionary<ulong,List<ulong[]>> warningWidgets=new Dictionary<ulong,List<ulong[]>>();
    readonly Dictionary<ulong,string> warningPartNames=new Dictionary<ulong,string>();
    void RegisterWarningTargets(List<Dictionary<string,object>> selected)
    {
        warningParts.Clear();warningWidgets.Clear();warningPartNames.Clear();engineWearTargets.Clear();
        foreach(var item in selected) {
            if(!item.ContainsKey("damagePart"))continue;
            var part=(Dictionary<string,object>)item["damagePart"];string name=(string)part["instanceId"];
            if(!String.Equals(name,"Engine",StringComparison.OrdinalIgnoreCase)&&!String.Equals(name,"Gearbox",StringComparison.OrdinalIgnoreCase))continue;
            try {
                ulong address=Convert.ToUInt64(((string)item["address"]).Substring(2),16),owner=U64(address+0x20),actor=U64(owner+0x20);
                if(!Ancestors(U64(owner+0x10)).Contains("CarDamageComponent")||!Ancestors(U64(actor+0x10)).Contains("CarAvatar"))continue;
                ulong car=U64(actor+0x580);if(!drivingTargets.ContainsKey(car))continue;
                if(!warningParts.ContainsKey(car))warningParts.Add(car,new List<ulong[]>());
                warningParts[car].Add(new ulong[]{address,owner,actor,U64(address+0x10),U32(address+12)});warningPartNames[address]=name;
                if(String.Equals(name,"Engine",StringComparison.OrdinalIgnoreCase))RegisterEngineWearTarget(car,address,owner,actor,part);
            }catch(Exception e){Warn("Component-warning target unavailable: "+e.Message);}
        }
        foreach(var item in selected) {
            if(!item.ContainsKey("dashboardWarning"))continue;
            try {
                ulong widget=Convert.ToUInt64(((string)item["address"]).Substring(2),16);
                byte[] a=Read(widget+0x3c0,16);ulong pointer=BitConverter.ToUInt64(a,0);int n=BitConverter.ToInt32(a,8),cap=BitConverter.ToInt32(a,12);
                if(!Ptr(pointer)||n<1||n>128||cap<n)continue;byte[] refs=Read(pointer,n*8);
                foreach(var target in warningParts){bool belongs=false;foreach(var part in target.Value)for(int i=0;i<n;i++)if(BitConverter.ToUInt64(refs,i*8)==part[0])belongs=true;
                    if(belongs){if(!warningWidgets.ContainsKey(target.Key))warningWidgets.Add(target.Key,new List<ulong[]>());warningWidgets[target.Key].Add(new ulong[]{widget,U64(widget+0x10),U32(widget+12)});}}
            }catch(Exception e){Warn("Dashboard-warning target unavailable: "+e.Message);}
        }
    }
    public static Dictionary<string,object> DecodeWarningPartState(byte[] part,byte[] states)
    {
        if(part==null||part.Length!=0x80||states==null||states.Length%32!=0||states.Length>64*32)throw new ArgumentException("Invalid warning-state extent.");
        int count=BitConverter.ToInt32(part,16),index=BitConverter.ToInt32(part,0x78);float maximum=BitConverter.ToSingle(part,0),life=BitConverter.ToSingle(part,0x7c);
        if(count!=states.Length/32||index<0||index>=count||Single.IsNaN(maximum)||Single.IsInfinity(maximum)||maximum<=0||Single.IsNaN(life)||Single.IsInfinity(life)||life<0||life>maximum*1.001f)throw new ArgumentException("Invalid component life/state in warning sample.");
        byte state=states[index*32+8];if(state>4)throw new ArgumentException("Unknown component severity enum.");
        return new Dictionary<string,object>{{"status","Captured"},{"componentLife",life},{"componentMaximumLife",maximum},{"componentLifePercent",100.0*life/maximum},{"componentStateIndex",index},{"componentStateType",state}};
    }
    Dictionary<string,object> ReadWarningEvidence(ulong car)
    {
        var result=new Dictionary<string,object>();var parts=new List<Dictionary<string,object>>();var widgets=new List<Dictionary<string,object>>();result["parts"]=parts;result["widgets"]=widgets;
        List<ulong[]> targets;
        if(warningParts.TryGetValue(car,out targets))foreach(var target in targets){var row=new Dictionary<string,object>();parts.Add(row);row["part"]=warningPartNames[target[0]];row["address"]=Hex(target[0]);
            try {
                ulong p=target[0];if(U64(p+0x10)!=target[3]||U32(p+12)!=target[4]||U64(p+0x20)!=target[1]||U64(target[1]+0x20)!=target[2]||U64(target[2]+0x580)!=car)throw new InvalidOperationException("Component identity changed.");
                byte[] bytes=Read(p+0xb8,0x80);int n=BitConverter.ToInt32(bytes,16),capacity=BitConverter.ToInt32(bytes,20);ulong states=BitConverter.ToUInt64(bytes,8);
                if(n<1||n>64||capacity<n||capacity>4096||!Ptr(states))throw new InvalidOperationException("Component state-array bounds failed.");
                var values=DecodeWarningPartState(bytes,Read(states,n*32));foreach(var value in values)row[value.Key]=value.Value;
                bool stable=U64(p+0x10)==target[3]&&U32(p+12)==target[4]&&U64(p+0x20)==target[1]&&SameBytes(bytes,Read(p+0xb8,0x80));row["stableAcrossRead"]=stable;
                if(!stable)row["status"]="Changed during read; discard this component sample";
            }catch(Exception e){row["status"]="Unavailable";row["error"]=e.Message;}}
        if(warningWidgets.TryGetValue(car,out targets))foreach(var target in targets){var row=new Dictionary<string,object>();widgets.Add(row);row["address"]=Hex(target[0]);
            try {ulong p=target[0];if(U64(p+0x10)!=target[1]||U32(p+12)!=target[2])throw new InvalidOperationException("HUD identity changed.");byte[] a=Read(p+0x3d0,2);if(a[0]>4)throw new InvalidOperationException("Unknown HUD severity.");
                row["storedHudSeverityType"]=a[0];row["initialized"]=a[1]!=0;row["stableAcrossRead"]=SameBytes(a,Read(p+0x3d0,2));row["status"]=(bool)row["stableAcrossRead"]?"Captured":"Changed during read";
            }catch(Exception e){row["status"]="Unavailable";row["error"]=e.Message;}}
        result["meaning"]="Observed component health/state and HUD cached severity, not a derived substitute. Unresolved tagged HUD references are not followed. No game functions or writes are used.";
        return result;
    }

    public Dictionary<string,object> Capture()
    {
        Dictionary<string,object> result=new Dictionary<string,object>();
        result["probeVersion"]="rc13-mechanical-observations";result["readOnly"]=true;result["capturedUtc"]=DateTime.UtcNow.ToString("o");
        result["moduleBase"]=Hex(imageBase);result["namePoolRva"]="0x0b27ba80";result["objectArrayRva"]="0x0b35f5a0";
        List<Dictionary<string,object>> selected=new List<Dictionary<string,object>>();result["objects"]=selected;
        try
        {
            if(Name(0,0)!="None")throw new InvalidOperationException("FName None check failed; no object traversal performed.");
            ulong arr=imageBase+0x0b35f5a0UL;
            byte[] h=Read(arr,48);chunks=BitConverter.ToUInt64(h,16);count=BitConverter.ToInt32(h,36);
            int max=BitConverter.ToInt32(h,32), maxChunks=BitConverter.ToInt32(h,40), numChunks=BitConverter.ToInt32(h,44);
            if(!Ptr(chunks)||count<1||count>3000000||max<count||max>100000000||numChunks<1||numChunks>8192||maxChunks<numChunks||(long)numChunks*65536<count)
                throw new InvalidOperationException("UObject registry dimensions failed validation.");
            result["objectCount"]=count;result["chunkCount"]=numChunks;
            int needed=(count+65535)/65536;byte[] chunkPointers=Read(chunks,needed*8);
            for(int c=0;c<needed;c++)
            {
                ulong ptr=BitConverter.ToUInt64(chunkPointers,c*8);int take=Math.Min(65536,count-c*65536);
                byte[] cells=Read(ptr,take*24);
                for(int i=0;i<take;i++)
                {
                    ulong obj=BitConverter.ToUInt64(cells,i*24);
                    if(Ptr(obj)&&!objectIndices.ContainsKey(obj))objectIndices.Add(obj,c*65536+i);
                }
            }
            // Both globals must resolve to registry members with their exact expected class names.
            ulong globalClass=U64(imageBase+0x0b522ad0UL);
            if(ObjectName(globalClass)!="PhysicsEngineSettings")throw new InvalidOperationException("PhysicsEngineSettings class check failed.");
            ulong compoundClass=U64(imageBase+0x0b520d80UL);
            if(ObjectName(compoundClass)!="TireCompound")throw new InvalidOperationException("TireCompound class check failed.");
            ulong partClass=U64(imageBase+0x0b5594e0UL);
            if(ObjectName(partClass)!="CarDamageablePart")throw new InvalidOperationException("CarDamageablePart class check failed.");
            result["identityChecks"]="None name + registry dimensions + three independently located native UClass singletons passed.";
            // Exact audited code ranges, read only; the caller compares against its
            // selected full-image manifest state. No game function is invoked.
            Dictionary<string,object> sites=new Dictionary<string,object>();
            ulong[] siteRvas=new ulong[]{0x04f6d58bUL,0x04f6d6e6UL,0x05eaef2fUL,0x04ef94c3UL,0x05003b6eUL,0x0500540cUL,0x050054b8UL,0x05ebb3d5UL,0x05eaefccUL,0x05eae0f0UL,0x05ebb390UL,0x00d22100UL,0x05eba6a6UL,0x05e91feaUL,0x00d22500UL,0x04f44610UL,0x05ebb3d9UL,0x05ebbdfbUL,0x088853e8UL,0x00d22900UL,0x00d03508UL,0x00cf5480UL,0x00d223b0UL,0x04f444d8UL,0x04f3573fUL,0x00d22420UL,0x00d4c89aUL,0x00d22fa0UL,0x00d220b1UL,0x04f444c2UL,0x04f44b00UL,0x04f44ba9UL,0x04f44c1eUL,0x04f4cb7cUL,0x04f4465cUL,0x04f435d2UL,0x04f43989UL,0x04f43898UL,0x04f43a26UL,0x04f43912UL};
            int[] siteSizes=new int[]{7,8,7,8,8,8,8,4,3,26,5,676,9,5,1024,8,5,5,24,1696,248,128,112,35,15,224,102,96,79,22,8,7,9,8,8,13,8,8,6,6};
            string[] siteNames=new string[]{"Tyre compression eligibility operand","Tyre compression accumulation operand","Mechanical failure eligibility operand","Brake consumption eligibility operand","Break threshold refresh operand","Fixed attachment threshold operand","Hinge attachment threshold operand","Collision critical admission","Mechanical failure critical admission","Cooling socket lookup entry","Engine impact weighting entry","Collision repair leaf routines","Progressive power response entry","Localized wheel collision entry","Progressive response leaf helpers","Gearbox grinding rate entry","Gearbox collision transfer entry","Gearbox accumulated Critical entry","Gearbox impact trampoline","Gearbox leaf helpers and unwind","Gearbox response helper","Gearbox timed-admission helpers","Suspension deformation helper","Gearbox timed-request entry","Suspension deformation entry","Admission observation helper","Shift result observation helper","Overrev observation helper","Grinding observation helper","Mechanical request entry","Admission observation entry","Shift result observation entry","Shift refusal observation entry","Overrev observation entry","Grinding observation entry","Unprotected downshift entry","Worn upshift duration entry","Worn downshift duration entry","Deferred upshift commit entry","Deferred downshift commit entry"};
            for(int si=0;si<siteRvas.Length;si++)
                sites[siteNames[si]]=BitConverter.ToString(Read(imageBase+siteRvas[si],siteSizes[si])).Replace("-","").ToLowerInvariant();
            result["nativeControlSites"]=sites;

            int valid=0;
            foreach(KeyValuePair<ulong,int> kv in objectIndices)
            {
                ulong o=kv.Key;
                try
                {
                    byte[] oh=Header(o);ulong cls=BitConverter.ToUInt64(oh,16);List<string> bases=Ancestors(cls);valid++;
                    bool global=bases.Contains("PhysicsEngineSettings"), material=bases.Contains("DMPhysicalMaterial"),
                         tyre=bases.Contains("TireCompound"), physics=bases.Contains("PhysicsAvatar"), car=bases.Contains("CarAvatar"),
                         damage=bases.Contains("CarDamagesData"), option=bases.Contains("OptionConfigurationDataAsset"),
                         part=bases.Contains("CarDamageablePart"), component=bases.Contains("CarDamageComponent"),
                         failurePolicy=bases.Contains("CarDamagePolicyMechanicalFailure"), wearPolicy=bases.Contains("CarDamagePolicyWear"),
                         collisionPolicy=bases.Contains("CarDamagePolicyCollisions"), modifiers=bases.Contains("CarPhysicsModifiersComponent"), hud=bases.Contains("AcrCarDamageStatusWidget");
                    if(!(global||material||tyre||physics||car||damage||option||part||component||failurePolicy||wearPolicy||collisionPolicy||modifiers||hud))continue;
                    string name=ObjectName(o);
                    if(option && !(name.IndexOf("Tyre",StringComparison.OrdinalIgnoreCase)>=0 || name.IndexOf("Damage",StringComparison.OrdinalIgnoreCase)>=0))continue;
                    Dictionary<string,object> item=Ref(o);item["index"]=kv.Value;item["classHierarchy"]=bases;
                    uint flags=BitConverter.ToUInt32(oh,8);bool cdo=(flags&0x10)!=0;item["classDefaultObject"]=cdo;item["objectFlags"]="0x"+flags.ToString("x");
                    try
                    {
                        if(modifiers&&!cdo)item["physicsModifierControls"]=ModifierComponent(o);
                        if(collisionPolicy){ValidateDamageTraceLayout();item["collisionPolicy"]=Floats(o,new int[]{0x68},new string[]{"CriticalDamageThreshold"});}
                        if(failurePolicy)item["mechanicalFailurePolicy"]=Floats(o,new int[]{0x90,0x94},new string[]{"MechanicalFailureThreshold","MechanicalFailureDistance"});
                        if(wearPolicy)item["componentWearPolicy"]=Floats(o,new int[]{0x90},new string[]{"WearRate"});
                        if(part&&!cdo)item["damagePart"]=DamagePart(o);
                        if(hud&&!cdo)item["dashboardWarning"]=new Dictionary<string,object>{{"storedSeverityType",Read(o+0x3d0,1)[0]},{"meaning","Native HUD cached state, not an inferred color"}};
                        if(component&&!cdo)item["damageComponent"]=DamageComponent(o);
                        if(global)item["values"]=GlobalSettings(o);
                        if(material)item["values"]=Material(o);
                        if(tyre)item["values"]=Compound(o);
                        if(physics&&!cdo)item["physics"]=Physics(o);
                        if(car&&!cdo){item["carData"]=Ref(U64(o+0x488));item["physicsDamageAccumulators"]=PhysicsDamageAccumulators(o);}
                        if(collisionPolicy&&!cdo&&bases.Contains("CarDamagePolicyCollisionsSockets"))item["registeredCollisionRouting"]=RegisteredCollisionSockets(o);
                    }
                    catch(Exception e){item["fieldReadError"]=e.Message;errors++;}
                    selected.Add(item);
                }
                catch(Exception){errors++;}
            }
            RegisterWarningTargets(selected);
            result["warningEvidenceApprovedCars"]=warningParts.Count;
            result["validatedObjects"]=valid;
            result["registryStillSame"]=U64(arr+16)==chunks && I32(arr+36)==count;
            if(!(bool)result["registryStillSame"])Warn("Objects changed during capture. Repeat while paused in a loaded stage for a steadier snapshot.");
            if(selected.Count==0)Warn("No targeted objects captured. This is not evidence that the systems are absent.");
            result["status"]="Completed";
        }
        catch(Exception e){result["status"]="Stopped safely";result["error"]=e.ToString();}
        result["readFailures"]=errors;result["bytesRead"]=bytesReadTotal;result["readCalls"]=readCalls;result["warnings"]=warnings;
        result["limitations"]="Non-atomic read-only snapshot. No game functions called. No settings written. No tyre-force/contact telemetry; part life is not proof of cooling or alignment behavior. No network or leaderboard blocking.";
        return result;
    }
}
