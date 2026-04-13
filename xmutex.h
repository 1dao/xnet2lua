// xmutex.h
#ifndef __XMUTEX_H__
#define __XMUTEX_H__
#ifdef __cplusplus
extern "C" {
#endif

#ifdef _WIN32
	#define WIN32_LEAN_AND_MEAN
	#include <windows.h>

	typedef CRITICAL_SECTION xMutex;
	#define xnet_mutex_init        InitializeCriticalSection
	#define xnet_mutex_uninit      DeleteCriticalSection
	#define xnet_mutex_lock        EnterCriticalSection
	#define xnet_mutex_unlock      LeaveCriticalSection
	#define xnet_mutex_trylock(mutex) (TryEnterCriticalSection(mutex) != 0)
#else
	#include <pthread.h>

	typedef pthread_mutex_t xMutex;

	static inline void xnet_mutex_init(xMutex* mutex) {
		pthread_mutexattr_t attr;
		pthread_mutexattr_init(&attr);
		pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
		pthread_mutex_init(mutex, &attr);
		pthread_mutexattr_destroy(&attr);
	}

	#define xnet_mutex_uninit      pthread_mutex_destroy
	#define xnet_mutex_lock        pthread_mutex_lock
	#define xnet_mutex_unlock      pthread_mutex_unlock
	#define xnet_mutex_trylock     pthread_mutex_trylock
#endif

#ifdef __cplusplus
}
#endif
#endif // __XMUTEX_H__
