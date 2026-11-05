@testable import AppBundle
import Testing

struct AnimationEchoesTest {
    @Test func testEchoIsRecognizedOnlyDuringGracePeriod() {
        let key = AnimationEchoKey(pid: 4242, nativeWindowId: 1)
        let writtenAt = ContinuousClock.now
        markAnimationEcho(key, now: writtenAt)

        assertTrue(isAnimationEcho(key, now: writtenAt + .milliseconds(10)))
        assertTrue(!isAnimationEcho(AnimationEchoKey(pid: 4242, nativeWindowId: 2), now: writtenAt + .milliseconds(10)))
        assertTrue(!isAnimationEcho(AnimationEchoKey(pid: 4243, nativeWindowId: 1), now: writtenAt + .milliseconds(10)))
        assertTrue(!isAnimationEcho(key, now: writtenAt + animationEchoGracePeriod))
    }

    @Test func testEveryWriteExtendsTheGracePeriod() {
        let key = AnimationEchoKey(pid: 4242, nativeWindowId: 3)
        let firstWrite = ContinuousClock.now
        markAnimationEcho(key, now: firstWrite)
        markAnimationEcho(key, now: firstWrite + .milliseconds(100))

        assertTrue(isAnimationEcho(key, now: firstWrite + .milliseconds(200)))
        assertTrue(!isAnimationEcho(key, now: firstWrite + .milliseconds(100) + animationEchoGracePeriod))
    }
}
