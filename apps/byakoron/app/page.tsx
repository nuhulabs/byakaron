import SpellChecker from "./components/SpellChecker";

export default function Home() {
  return (
    <div className="app-container">
      {/* Animated Background */}
      <div className="bg-grid" />
      <div className="bg-glow bg-glow-1" />
      <div className="bg-glow bg-glow-2" />
      <div className="bg-glow bg-glow-3" />

      <main className="main-content">
        {/* Header */}
        <header className="header">
          <div className="logo-section">
            <div className="logo">
              <span className="logo-icon">ব্যা</span>
            </div>
            <div className="logo-text">
              <h1 className="app-title">ব্যাকরণ</h1>
              <p className="app-subtitle">Byakoron - Bangla Grammar Tool</p>
            </div>
          </div>

          <nav className="nav-tabs">
            <button className="nav-tab active">
              <span className="tab-icon">✓</span>
              বানান
              <span className="tab-label">Spelling</span>
            </button>
            <button className="nav-tab disabled" disabled title="Coming soon">
              <span className="tab-icon">📝</span>
              ব্যাকরণ
              <span className="tab-label">Grammar</span>
              <span className="coming-soon">শীঘ্রই</span>
            </button>
          </nav>
        </header>

        {/* Spell Checker Component */}
        <SpellChecker />

        {/* Footer */}
        <footer className="footer">
          <div className="footer-content">
            <span className="powered-by">
              Powered by{" "}
              <a href="https://github.com/nurulhudaapon/bntk" target="_blank" rel="noopener noreferrer">
                BNTK
              </a>
            </span>
            <span className="separator">•</span>
            <span className="tech-stack">
              PostgreSQL + pg_trgm + Phonetic Matching
            </span>
          </div>
        </footer>
      </main>
    </div>
  );
}
