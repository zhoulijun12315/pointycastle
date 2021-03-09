// Copyright (c) 2013-present, the authors of the Pointy Castle project
// This library is dually licensed under LGPL 3 and MPL 2.0.
// See file LICENSE for more information.

library pointycastle.impl.asymmetric_block_cipher.oeap;

import "dart:typed_data";
import "dart:math";

import "package:pointycastle/api.dart";
import "package:pointycastle/src/registry/registry.dart";
import "package:pointycastle/src/impl/base_asymmetric_block_cipher.dart";
import "package:pointycastle/random/fortuna_random.dart";
import "package:pointycastle/digests/sha1.dart";
import "package:pointycastle/digests/sha3.dart";
import "package:pointycastle/digests/sha256.dart";

/// RSAES-OAEP v2.0
///
/// This implementation is based on the RSAES-OAEP (RSA Encryption Scheme -
/// Optimal Asymmetric Encryption Padding) as specified in section 7.1 of
/// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-7.1)
/// _PKCS #1: RSA Cryptography Specifications Version 2.0_.
///
/// **Important:** this is **not** compatible with RSAES-OAEP v2.1 or later (as
/// specified in RFC 3447, RFC 8017, etc.) Those newer versions have an extra
/// 0x00 byte at the beginning of the encoded message (EM) that is passed
/// to the RSA encryption primitive. Therefore, this implementation is
/// incompatible with it, since this is an implementation of v2.0 which does
/// not have that 0x00 byte. A breaking change in the standard!
///
/// Currently, this implementation has the following restrictions:
///
/// - the hash function is hard-coded to be SHA-1;
/// - the mask generation function is hard-coded to MGF1; and
/// - it cannot accept any _encoding parameters_ (that is, _P_ is always empty)

class OAEPEncoding extends BaseAsymmetricBlockCipher {
  /// Intended for internal use.
  static final FactoryConfig FACTORY_CONFIG = new DynamicFactoryConfig.suffix(
      AsymmetricBlockCipher,
      "/OAEP",
      (_, final Match match) => () {
            AsymmetricBlockCipher underlyingCipher =
                new AsymmetricBlockCipher(match.group(1));
            return new OAEPEncoding(underlyingCipher);
          });

  /// Hash function used by the EME-OAEP (Encoding Method for Encryption OAEP).
  // MARK: MegaSDK need hash is SHA256Digest
  // Digest hash = SHA1Digest();
  Digest hash = SHA256Digest();

  /// Hash function used by the MGF1 Mask Generation Function.
  Digest mgf1Hash;

  /// Hash of the encoding parameters.
  ///
  /// Note: in this implementation the encoding parameters is always zero
  /// octets. There is no mechanism to provide encoding parameters.
  // MARK: MegaSDK need hash is SHA256Digest
  // Uint8List defHash = Uint8List(SHA1Digest().digestSize);

  Uint8List defHash = Uint8List(SHA256Digest().digestSize);

  final AsymmetricBlockCipher _engine;
  SecureRandom _random;
  bool _forEncryption;

  OAEPEncoding(this._engine) {
    // MARK: MegaSDK need SHA3_256 doFinal
    // SHA1Digest().doFinal(defHash, 0);

    SHA3Digest(256).doFinal(defHash, 0);
  }

  String get algorithmName => "${_engine.algorithmName}/OAEP";

  void reset() {}

  Uint8List _seed() {
    var random = new Random.secure();
    List<int> seeds = [];
    for (int i = 0; i < 32; i++) {
      seeds.add(random.nextInt(255));
    }
    return new Uint8List.fromList(seeds);
  }

  // for compat cleaner translation from java source
  Uint8List _arraycopy(
      Uint8List src, int srcPos, Uint8List dest, int destPos, int length) {
    dest.setRange(
        destPos, destPos + length, src.sublist(srcPos, srcPos + length));
    return dest;
  }

  void init(bool forEncryption, CipherParameters params) {
    AsymmetricKeyParameter akparams;
    mgf1Hash = hash;
    if (params is ParametersWithRandom) {
      ParametersWithRandom paramswr = params;
      _random = paramswr.random;
      akparams = paramswr.parameters;
    } else {
      _random = new FortunaRandom();
      _random.seed(KeyParameter(_seed()));
      akparams = params;
    }
    _engine.init(forEncryption, akparams);
    _forEncryption = forEncryption;

    // Check type of key provided is suitable
    // Note: the _engine can't do this check, becuase the engine could be used
    // for both encryption/decryption and signature/verification (which reverses
    // the keys), so its `init` method accepts both types of keys. For example,
    // [RSAEngine.init].

    if (forEncryption) {
      if (akparams.key is! PublicKey) {
        throw ArgumentError.value(
            'OAEP encryption needs PublicKey: not ${akparams.key.runtimeType}');
      }
    } else {
      if (akparams.key is! PrivateKey) {
        throw ArgumentError.value(
            'OAEP decryption needs PrivateKey: not ${akparams.key.runtimeType}');
      }
    }
  }

  int get inputBlockSize {
    var baseBlockSize = _engine.inputBlockSize;
    if (_forEncryption) {
      return baseBlockSize - 1 - 2 * defHash.length;
    } else {
      return baseBlockSize;
    }
  }

  int get outputBlockSize {
    var baseBlockSize = _engine.outputBlockSize;
    if (_forEncryption) {
      return baseBlockSize;
    } else {
      return baseBlockSize - 1 - (2 * defHash.length);
    }
  }

  int processBlock(
      Uint8List inp, int inpOff, int len, Uint8List out, int outOff) {
    if (_forEncryption) {
      return _encodeBlock(inp, inpOff, len, out, outOff);
    } else {
      return _decodeBlock(inp, inpOff, len, out, outOff);
    }
  }

  /// RSAES-OAEP encryption operation
  ///
  /// Implements the _RSA Encryption Scheme with Optimal Asymmetric Encryption
  /// Padding_ (RSAES-OAEP) **encryption operation**. This encryption operation
  /// combines the _Encoding Method for Encryption OAEP_ (EME-OAEP)
  /// **encoding operation** with the _RSA Encryption Primitive_ (RSAEP).
  ///
  /// This method performs the EME-OAEP encoding operation, and then invokes its
  /// [AsymmetricBlockCipher] engine to perform RSAEP to encrypt it.
  ///
  /// The RSAES-OAEP encryption operation is specified in section 7.1.1 of
  /// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-7.1.1) and the
  /// EME-OAEP encoding operation it uses is specified in section 9.1.1.1 of
  /// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-9.1.1.1).
  ///
  /// The message to be encoded and encrypted is the octet string consisting of
  /// [inpLen] bytes from [inp], starting at the [inpOff] offset.
  ///
  /// It returns the ciphertext.

  int _encodeBlock(
      Uint8List inp, int inpOff, int inpLen, Uint8List out, int outOff) {
    if (inpLen > inputBlockSize) {
      throw new ArgumentError("message too long");
    }

    // The numbered steps below correspond to the steps in RFC 2437.
    // Names in _italics_ refers to names in the RFC 2437 and names in square
    // brackets refers to variables in this code.

    // 3. Generate PS (padding string containing just zero octets)
    //
    // In this implementation, the length of PS is always zero. That is, there
    // is no bytes in _PS_.

    // 4. Calculate _pHash_ = Hash(P)
    //
    // The result _pHash_ is stored into [pHash].
    //
    // defHash = hash.process(encodingParams);

    // Note: This implementation currently does not support encodingParams
    // so the [defHash] is used as is (which was initialized to be a hash of no
    // bytes). (Not sure why it is a member variable instead of a variable
    // local to this method.)

    // 5. Create the _DB_ data block.
    //
    // It is the concatenation of _pHash_, _PS_, 0x01 and the message.
    // Note: RFC 2437 also includes "other padding", but that is an error that
    // does not appear in subsequent versions of PKCS #1 (e.g. RFC 3447).
    //
    // The result _DB_ is stored into [block] starting at offset _hLen_ to the
    // end.

    var block = new Uint8List(inputBlockSize + 1 + 2 * defHash.length);

    //
    // copy in the message
    //
    // block.setRange(inpOff, block.length - inpLen, inp.sublist(inpLen));
    block = _arraycopy(inp, inpOff, block, block.length - inpLen, inpLen);

    //
    // add sentinel
    //
    block[block.length - inpLen - 1] = 0x01;

    //
    // as the block is already zeroed - there's no need to add PS (the >= 0 pad of 0)
    //

    //
    // add the hash of the encoding params.
    //
    block = _arraycopy(defHash, 0, block, defHash.length, defHash.length);

    // 6. Generate a random octet string _seed_ of length _hLen_.
    //
    // The _seed_ is stored in [seed].

    Uint8List seed = _random.nextBytes(defHash.length);

    // 7. Calculate _dbMask_ = MGF(seed, emLen - hLen)
    //
    // The _seed_ comes from [seed]. The result _dbMask_ is stored into [mask].

    Uint8List mask = _maskGeneratorFunction1(
        seed, 0, seed.length, block.length - defHash.length);

    // 8. Calculate _maskedDB_ = DB XOR dbMask
    //
    // The _DB_ comes from [block], starting at offset _hLen_ to the end. The
    // _dbMask_ comes from [mask]. The result _maskedDB_ is stored into [block]
    // starting at offset _hLen_ to the end (overwriting the _DB_).

    for (int i = defHash.length; i != block.length; i++) {
      block[i] ^= mask[i - defHash.length];
    }

    // Temporally store the _seed_ in the first _hLen_ bytes of the [block]
    // so it can be used later.

    block = _arraycopy(seed, 0, block, 0, defHash.length);

    // 9. Calculate _seedMask_ = MGF(maskDB, hLen)
    //
    // The _maskDB_ comes from [block], starting at offset _hLen_ to the end.
    // The result _seedMask_ is stored into [mask] (replacing the _dbMask_ which
    // is no longer needed).

    mask = _maskGeneratorFunction1(
        block, defHash.length, block.length - defHash.length, defHash.length);

    // 10. Calculate _maskedSeed_ = seed XOR seedMask
    //
    // The _seed_ comes from [block], the first _hLen_ bytes (where it was
    // temporally stored). The _seedMask_ comes from [mask]. The result
    // _maskedSeed_ is stored into [block], the first _hLen_ bytes (overwriting
    // the temporary _seed_).

    for (int i = 0; i != defHash.length; i++) {
      block[i] ^= mask[i];
    }

    // 11. Calculate _EM_ = maskedSeed || maskedDB
    //
    // The [block] already contains the concatenated value, since they were both
    // calculated in the first.

    // EME-OAEP-ENCODE completed.

    // Use the [_engine] to finish the RSAES-OAEP. That is, it will convert the
    // _EM_ into an integer, apply the RSA Encryption Primitive (RSAEP) to the
    // public key, and convert the resulting integer ciphertext representation
    // into octets. The octets will be written into [out] starting at [outOff].
    //
    // Returns the number of bytes in the output ciphertext.

    return _engine.processBlock(block, 0, block.length, out, outOff);
  }

  /// RSAES-OAEP decryption operation
  ///
  /// Implements the _RSA Encryption Scheme with Optimal Asymmetric Encryption
  /// Padding_ (RSAES-OAEP) **decryption operation**. This decryption operation
  /// combines the _RSA Decryption Primitive_ (RSADP) with the _Encoding Method
  /// for Encryption OAEP_ (EME-OAEP) **decoding operation**.
  ///
  /// This method invokes its [AsymmetricBlockCipher] engine to perform RSADP,
  /// and then performs the EME-OAEP decoding operation on the decrypted data.
  ///
  /// The RSAES-OAEP decryption operation is specified in section 7.1.2 of
  /// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-7.1.2) and the
  /// EME-OAEP decoding operation it uses is specified in section 9.1.1.2 of
  /// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-9.1.1.2).
  ///
  /// The ciphertext to be decrypted and decoded is the octet string consisting
  /// of [inpLen] bytes from [inp], starting at the [inpOff] offset.
  ///
  /// It returns the message in [out] starting at offset [offOut].

  int _decodeBlock(
      Uint8List inp, int inpOff, int inpLen, Uint8List out, int outOff) {
    // The numbered steps below correspond to the steps from section 7.1.2 of
    // [RFC 2437](https://tools.ietf.org/html/rfc2437#section-7.1.2).
    //
    // Names in _italics_ refers to names in the RFC 2437 and names in square
    // brackets refers to variables in this code.

    // 1. Length checking

    if (inpLen != _engine.inputBlockSize) {
      throw ArgumentError.value(inpLen, 'inpLen', 'decryption error');
    }

    // 2, 3, 4. RSA decryption
    // This saves the _EM_ into [block].

    var block = new Uint8List(_engine.inputBlockSize);
    var len = _engine.processBlock(inp, inpOff, inpLen, block, 0);
    block = block.sublist(0, len);

    // 5. EME-OAEP decoding
    //
    // In these 5.x numbered steps, the x refers to steps from section 9.1.1.2
    // of [RFC 2437](https://tools.ietf.org/html/rfc2437#section-9.1.1.2)

    // 5.2 Check length

    bool wrongData = (block.length < (2 * defHash.length) + 1);

    // 5.4 Calculate _seedMask_ = MGF(maskedDB, hLen)
    //
    // The _maskedDB_ comes from [block] starting at _hLen_ to the end.
    // The result _seedMask_ is stored in [mask].

    Uint8List mask = _maskGeneratorFunction1(
        block, defHash.length, block.length - defHash.length, defHash.length);

    // 5.5 Calculate _seed_ = maskedSeed XOR seedMask
    //
    // THe _maskedSeed_ comes from the first _hLen_ bytes of [block] and the
    // _seedMask_ comes from [mask].
    // The result _seed_ is stored in the first _hLen_ bytes of [block]
    // (overwriting the maskedSeed_ that was previously there).

    for (int i = 0; i != defHash.length; i++) {
      block[i] ^= mask[i];
    }

    // 5.6 Calculate _dbMask_ = MGF(seed, length of EM - hLen)

    mask = _maskGeneratorFunction1(
        block, 0, defHash.length, block.length - defHash.length);

    // 5.7 Calculate _DB_ = maskedDB XOR dbMask
    //
    // The _maskedDB_ comes from [block], from _hLen_ to the end, and the
    // _dbMask_ comes from [mask]. The result _DB_ is stored in [block] from
    // _hLen_ to the end (overwriting the _maskedDB_ that was previously there).

    for (int i = defHash.length; i != block.length; i++) {
      block[i] ^= mask[i - defHash.length];
    }

    // 5.8 pHash = Hash(P)
    //
    // Since in this implementation P is always an empty octet string, _pHash_
    // is already the value in _defHash_.

    // 5.10 Check _pHash'_ to _pHash_
    //
    // check the hash of the encoding params.
    // long check to try to avoid this been a source of a timing attack.
    //
    // The _pHash'_ comes from the first _hLen_ bytes of [block]

    bool defHashWrong = false;

    for (int i = 0; i != defHash.length; i++) {
      if (defHash[i] != block[defHash.length + i]) {
        defHashWrong = true;
      }
    }

    // 5.9 Split _DB_ into pHash1 || PS || 0x01 || M
    //
    // Skip over the _PS_ (which are all 0x00 bytes). Finding the first non-zero
    // byte from hash.digestLength * 2 to the end of [block]. Setting [start]
    // to that first non-zero byte (or will be block.length if none found).

    int start = block.length;
    for (int index = 2 * defHash.length; index != block.length; index++) {
      if ((block[index] != 0) & (start == block.length)) {
        start = index;
      }
    }

    // The data-start-is-wrong if the rest of the [block] contains all 0x00
    // bytes or that first non-zero byte is not 0x01.

    bool dataStartWrong = (start > (block.length - 1)) | (block[start] != 1);
    start++;

    if (defHashWrong | wrongData | dataStartWrong) {
      block.fillRange(0, block.length, 0);
      throw new ArgumentError("decoding error");
    }

    // 5.11 Output M
    //
    // The _M_ are all the bytes from after the 0x01 byte (i.e. offset [start])
    // to the end of [block]. Copy those bytes into [out] starting at [outOff].

    final mLen = block.length - start;
    _arraycopy(block, start, out, outOff, mLen);
    return mLen;
  }

  /**
  * int to octet string.
  */
  Uint8List _ItoOSP(int i, Uint8List sp) {
    sp[0] = i >> 24;
    sp[1] = i >> 16;
    sp[2] = i >> 8;
    sp[3] = i >> 0;
    return sp;
  }

  /// Implementation of MGF1 (the Mask Generation Function from PKCS #1 v2.0).
  ///
  /// See section 10.2.1 of
  /// [RFC 2437](https://tools.ietf.org/html/rfc2437#section-10.2.1).
  ///
  /// MGF1 is defined to take a hash function as an option. This implementation
  /// uses [mgf1Hash] for that hash function.
  ///
  /// MGF1 hsa two inputs: a seed and an intended length. The seed is the
  /// sequence of bytes in [Z], starting at [zOff] for [zLen] bytes.
  /// The intended length is in [length].
  ///
  /// Returns the calculated mask. A Uint8List that contains [length] bytes.

  Uint8List _maskGeneratorFunction1(
      Uint8List Z, int zOff, int zLen, int length) {
    Uint8List mask = Uint8List(length);
    Uint8List hashBuf = Uint8List(mgf1Hash.digestSize);
    Uint8List C = Uint8List(4);
    int counter = 0;
    mgf1Hash.reset();

    while (counter < (length / hashBuf.length).floor()) {
      _ItoOSP(counter, C);
      mgf1Hash.update(Z, zOff, zLen);
      mgf1Hash.update(C, 0, C.length);
      mgf1Hash.doFinal(hashBuf, 0);
      mask = _arraycopy(
          hashBuf, 0, mask, counter * hashBuf.length, hashBuf.length);
      counter++;
    }

    if ((counter * hashBuf.length) < length) {
      _ItoOSP(counter, C);
      mgf1Hash.update(Z, zOff, zLen);
      mgf1Hash.update(C, 0, C.length);
      mgf1Hash.doFinal(hashBuf, 0);
      mask = _arraycopy(hashBuf, 0, mask, counter * hashBuf.length,
          mask.length - (counter * hashBuf.length));
    }
    return mask;
  }
}
