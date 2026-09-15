import { BrowserRouter, Routes, Route, Navigate } from 'react-router-dom';
import { AuthProvider, useAuth } from './lib/auth';
import Login from './screens/Login';
import Kitchen from './screens/Kitchen';
import Waiter from './screens/Waiter';
import Attendance from './screens/Attendance';
import { ReactNode } from 'react';

function ProtectedRoute({ children }: { children: ReactNode }) {
  const { user, loading } = useAuth();
  if (loading) return <div className="loading"><div className="spinner" /></div>;
  if (!user) return <Navigate to="/login" replace />;
  return <>{children}</>;
}

function RoleRedirect() {
  const { user, loading } = useAuth();
  if (loading) return <div className="loading"><div className="spinner" /></div>;
  if (!user) return <Navigate to="/login" replace />;
  const role = (user.role || '').toUpperCase();
  if (role === 'COCINA' || role === 'ASADOR') return <Navigate to="/cocina" replace />;
  return <Navigate to="/mesero" replace />;
}

export default function App() {
  return (
    <BrowserRouter>
      <AuthProvider>
        <Routes>
          <Route path="/login" element={<Login />} />
          <Route path="/cocina" element={<ProtectedRoute><Kitchen /></ProtectedRoute>} />
          <Route path="/mesero" element={<ProtectedRoute><Waiter /></ProtectedRoute>} />
          <Route path="/asistencia" element={<Attendance />} />
          <Route path="/" element={<RoleRedirect />} />
          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AuthProvider>
    </BrowserRouter>
  );
}
