// Soiva default SynthDef
// Load this in SuperCollider or let Soiva auto-load via sclang

s.waitForBoot {
    SynthDef(\default, { |out = 0, freq = 440, amp = 0.8, pan = 0, attack = 0.01, release = 0.5, gate = 1, cutoff = 2000, res = 0.3|
        var sig, env;
        env = EnvGen.kr(Env.perc(attack, release), doneAction: 2);
        sig = SinOsc.ar(freq, 0, amp);
        sig = sig + (Saw.ar(freq * 1.002, amp * 0.3));
        sig = RLPF.ar(sig, cutoff, res);
        sig = sig * env;
        sig = Pan2.ar(sig, pan);
        Out.ar(out, sig);
    }).add;

    SynthDef(\pad, { |out = 0, freq = 440, amp = 0.5, pan = 0, attack = 0.5, release = 2.0, gate = 1, cutoff = 1500, res = 0.4|
        var sig, env;
        env = EnvGen.kr(Env.perc(attack, release), doneAction: 2);
        sig = Saw.ar([freq, freq * 1.005], amp * 0.5);
        sig = Mix.ar(sig);
        sig = RLPF.ar(sig, cutoff, res);
        sig = sig * env;
        sig = Pan2.ar(sig, pan);
        Out.ar(out, sig);
    }).add;

    SynthDef(\pluck, { |out = 0, freq = 440, amp = 0.8, pan = 0, attack = 0.001, release = 0.3|
        var sig, env;
        env = EnvGen.kr(Env.perc(attack, release), doneAction: 2);
        sig = Pluck.ar(WhiteNoise.ar(amp), Impulse.kr(0), freq.reciprocal, freq.reciprocal, 5, 0.5);
        sig = sig * env;
        sig = Pan2.ar(sig, pan);
        Out.ar(out, sig);
    }).add;

    "Soiva SynthDefs loaded.".postln;
};
