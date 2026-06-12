package mobile

import (
	"bufio"
	"os"
	"sync"
)

// stdoutInterceptor swaps os.Stdout / os.Stderr with pipe write ends and
// forwards every line read from the pipes to the supplied sink.
type stdoutInterceptor struct {
	sink func(line string)

	origStdout *os.File
	origStderr *os.File
	wStdout    *os.File
	rStdout    *os.File
	wStderr    *os.File
	rStderr    *os.File

	wg     sync.WaitGroup
	doneCh chan struct{}
	once   sync.Once
}

func newStdoutInterceptor(sink func(string)) *stdoutInterceptor {
	return &stdoutInterceptor{sink: sink, doneCh: make(chan struct{})}
}

func (s *stdoutInterceptor) start() error {
	rOut, wOut, err := os.Pipe()
	if err != nil {
		return err
	}
	rErr, wErr, err := os.Pipe()
	if err != nil {
		_ = rOut.Close()
		_ = wOut.Close()
		return err
	}

	s.origStdout = os.Stdout
	s.origStderr = os.Stderr
	s.rStdout, s.wStdout = rOut, wOut
	s.rStderr, s.wStderr = rErr, wErr
	os.Stdout = wOut
	os.Stderr = wErr

	s.wg.Add(2)
	go s.drain(rOut)
	go s.drain(rErr)
	return nil
}

func (s *stdoutInterceptor) drain(r *os.File) {
	defer s.wg.Done()
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for scanner.Scan() {
		if s.sink != nil {
			s.sink(scanner.Text())
		}
	}
}

func (s *stdoutInterceptor) stop() {
	s.once.Do(func() {
		// Restore originals first so anything emitted during shutdown goes
		// to the real fds (which on iOS are /dev/null but harmless).
		if s.origStdout != nil {
			os.Stdout = s.origStdout
		}
		if s.origStderr != nil {
			os.Stderr = s.origStderr
		}
		_ = s.wStdout.Close()
		_ = s.wStderr.Close()
		s.wg.Wait()
		_ = s.rStdout.Close()
		_ = s.rStderr.Close()
		close(s.doneCh)
	})
}
