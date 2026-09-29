// Bounded byte operations for offline custom tuning. No process access or game calls.
using System;
using System.IO;
using System.Globalization;
using System.Security.Cryptography;
public static class ACRCustomBytes {
 public static string Hash(byte[] b){using(var h=SHA256.Create())return Hex(h.ComputeHash(b));}
 public static string Hex(byte[] b){return BitConverter.ToString(b).Replace("-","").ToLowerInvariant();}
 public static byte[] Unhex(string s){if(s==null||s.Length%2!=0)throw new ArgumentException("Invalid hex");var b=new byte[s.Length/2];for(int i=0;i<b.Length;i++)b[i]=Convert.ToByte(s.Substring(2*i,2),16);return b;}
 public static bool Equal(byte[] a,byte[] b){if(a.Length!=b.Length)return false;int d=0;for(int i=0;i<a.Length;i++)d|=a[i]^b[i];return d==0;}
 public static byte[] Slice(byte[] b,int off,int len){if(off<0||len<0||off>b.Length-len)throw new ArgumentOutOfRangeException();var r=new byte[len];Buffer.BlockCopy(b,off,r,0,len);return r;}
 public static void Put(byte[] b,int off,byte[] value){if(off<0||off>b.Length-value.Length)throw new ArgumentOutOfRangeException();Buffer.BlockCopy(value,0,b,off,value.Length);}
 public static string Number(double v){float f=(float)v;if(float.IsNaN(f)||float.IsInfinity(f))throw new ArgumentException("Non-finite custom value");if(v!=0&&f==0)throw new ArgumentException("Value is too small to store as a nonzero native float");return Expand(f.ToString("R",CultureInfo.InvariantCulture));}
 static string Expand(string s){
  int e=s.IndexOf('E');if(e<0)return s;
  int exp=int.Parse(s.Substring(e+1),CultureInfo.InvariantCulture);string m=s.Substring(0,e),sign="";
  if(m.StartsWith("-",StringComparison.Ordinal)){sign="-";m=m.Substring(1);}
  int dot=m.IndexOf('.'),point=(dot<0?m.Length:dot)+exp;string digits=m.Replace(".","");
  if(point<=0)return sign+"0."+new string('0',-point)+digits;
  if(point>=digits.Length)return sign+digits+new string('0',point-digits.Length);
  return sign+digits.Substring(0,point)+"."+digits.Substring(point);
 }
 public static uint Checksum(byte[] b){
  if(b.Length<0x100)throw new ArgumentException("Not a PE image");int pe=BitConverter.ToInt32(b,0x3c),off=pe+24+64;
  if(pe<64||off>b.Length-4||BitConverter.ToUInt32(b,pe)!=0x4550)throw new ArgumentException("PE header mismatch");
  ulong sum=0;for(int i=0;i<b.Length;i+=2){if(i==off||i==off+2)continue;sum+=(uint)(b[i]|(i+1<b.Length?b[i+1]<<8:0));}
  while((sum>>16)!=0)sum=(sum&65535)+(sum>>16);return (uint)(sum+(uint)b.Length);
 }
 public static void SetChecksum(byte[] b){Put(b,BitConverter.ToInt32(b,0x3c)+88,BitConverter.GetBytes(Checksum(b)));}
 // BLAKE3 unkeyed, ONE CHUNK ONLY, 0..1024 bytes. All audited assets are <=1000.
 // Based on the CC0 BLAKE3 reference algorithm, not a general cryptography API.
 static readonly uint[] IV={0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19};
 static readonly int[] Perm={2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8};
 static uint Rot(uint a,int n){return (a>>n)|(a<<(32-n));}
 static void G(uint[] v,int a,int b,int c,int d,uint x,uint y){unchecked{v[a]+=v[b]+x;v[d]=Rot(v[d]^v[a],16);v[c]+=v[d];v[b]=Rot(v[b]^v[c],12);v[a]+=v[b]+y;v[d]=Rot(v[d]^v[a],8);v[c]+=v[d];v[b]=Rot(v[b]^v[c],7);}}
 static uint[] Compress(uint[] cv,uint[] msg,int len,uint flags){
  var v=new uint[16];Array.Copy(cv,v,8);Array.Copy(IV,0,v,8,4);v[14]=(uint)len;v[15]=flags;
  for(int round=0;round<7;round++){
   G(v,0,4,8,12,msg[0],msg[1]);G(v,1,5,9,13,msg[2],msg[3]);G(v,2,6,10,14,msg[4],msg[5]);G(v,3,7,11,15,msg[6],msg[7]);
   G(v,0,5,10,15,msg[8],msg[9]);G(v,1,6,11,12,msg[10],msg[11]);G(v,2,7,8,13,msg[12],msg[13]);G(v,3,4,9,14,msg[14],msg[15]);
   var next=new uint[16];for(int j=0;j<16;j++)next[j]=msg[Perm[j]];msg=next;
  }
  for(int j=0;j<8;j++){v[j]^=v[j+8];v[j+8]^=cv[j];}return v;
 }
 public static string Blake160(byte[] b){
  if(b==null||b.Length>1024)throw new ArgumentException("Asset exceeds audited single-chunk BLAKE3 scope");
  var cv=(uint[])IV.Clone();int blocks=Math.Max(1,(b.Length+63)/64);uint[] output=null;
  for(int k=0;k<blocks;k++){
   int count=Math.Min(64,b.Length-k*64);var block=new byte[64];if(count>0)Buffer.BlockCopy(b,k*64,block,0,count);
   var msg=new uint[16];for(int i=0;i<16;i++)msg[i]=BitConverter.ToUInt32(block,i*4);
   uint flags=(uint)(k==0?1:0);if(k==blocks-1)flags|=2|8;
   output=Compress(cv,msg,count,flags);Array.Copy(output,cv,8);
  }
  var raw=new byte[20];for(int i=0;i<5;i++)Put(raw,i*4,BitConverter.GetBytes(output[i]));return Hex(raw);
 }
}
