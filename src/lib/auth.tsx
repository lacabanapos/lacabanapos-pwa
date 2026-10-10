import { createContext, useContext, useEffect, useState, ReactNode } from 'react';
import { User, LocationUser } from '../types';
import { supabase } from './supabase';

const PWA_TOKEN_KEY = 'pwa_operator_token_v1';
const OWNER_SESSION_KEY = 'pwa_owner_session_v1';

export function getOperatorToken() {
  return localStorage.getItem(PWA_TOKEN_KEY);
}

interface AuthContextType {
  user: User | null;
  locationId: string | null;
  locationName: string | null;
  locationUsers: LocationUser[];
  ownerInspection: boolean;
  loading: boolean;
  login: (userId: string, password: string) => Promise<void>;
  loginSuperadmin: (email: string, password: string) => Promise<void>;
  enterBranch: (targetLocationId: string) => Promise<void>;
  returnToBranches: () => void;
  logout: () => void;
  setLocation: (locationId: string, locationName: string) => Promise<void>;
  isAdmin: boolean;
  isCocina: boolean;
}

const AuthContext = createContext<AuthContextType>({
  user: null,
  locationId: null,
  locationName: null,
  locationUsers: [],
  ownerInspection: false,
  loading: true,
  login: async () => {},
  loginSuperadmin: async () => {},
  enterBranch: async () => {},
  returnToBranches: () => {},
  logout: () => {},
  setLocation: async () => {},
  isAdmin: false,
  isCocina: false,
});

export function useAuth() {
  return useContext(AuthContext);
}

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null);
  const [locationId, setLocationId] = useState<string | null>(null);
  const [locationName, setLocationName] = useState<string | null>(null);
  const [locationUsers, setLocationUsers] = useState<LocationUser[]>([]);
  const [ownerInspection, setOwnerInspection] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Restore session from localStorage
    const savedUser = localStorage.getItem('pwa_user');
    const savedLoc = localStorage.getItem('pwa_location_id');
    const savedLocName = localStorage.getItem('pwa_location_name');
    const savedToken = localStorage.getItem(PWA_TOKEN_KEY);

    if (savedUser && savedLoc && savedToken) {
      try {
        const restoredUser = JSON.parse(savedUser) as User;
        setUser(restoredUser);
        setOwnerInspection(!!localStorage.getItem(OWNER_SESSION_KEY));
        setLocationId(savedLoc);
        setLocationName(savedLocName);
        loadLocationUsers(savedLoc);
      } catch {
        localStorage.removeItem('pwa_user');
        localStorage.removeItem('pwa_location_id');
        localStorage.removeItem('pwa_location_name');
      }
    }
    setLoading(false);
  }, []);

  async function loadLocationUsers(locId: string) {
    try {
    const { data, error } = await supabase.rpc('get_location_users', {
        p_location_id: locId,
      });
      if (error) throw error;
      setLocationUsers(data || []);
    } catch (err) {
      console.error('Error loading location users:', err);
      setLocationUsers([]);
    }
  }

  // The selector stays current while the phone is waiting at login. Staff
  // changes made on the desktop therefore do not require clearing browser
  // data or reopening the PWA.
  useEffect(() => {
    if (!locationId || user) return;
    void loadLocationUsers(locationId);
    const timer = window.setInterval(() => void loadLocationUsers(locationId), 15000);
    return () => window.clearInterval(timer);
  }, [locationId, user]);

  async function setLocation(locId: string, locName: string) {
    setLocationId(locId);
    setLocationName(locName);
    localStorage.setItem('pwa_location_id', locId);
    localStorage.setItem('pwa_location_name', locName);
    await loadLocationUsers(locId);
  }

  async function login(userId: string, password: string) {
    if (!locationId) throw new Error('Selecciona una sucursal primero');

    localStorage.removeItem(PWA_TOKEN_KEY);
    const { data, error } = await supabase.rpc('pos_login_session_by_user_id', {
      p_user_id: userId,
      p_password: password,
      p_location_id: locationId,
    });

    if (error) throw error;
    if (!data || data.length === 0) throw new Error('Credenciales incorrectas');

    const u = data[0];
    if (!u?.session_token || !u?.user_id) throw new Error('No se pudo crear la sesión cloud. Intenta nuevamente.');
    const newUser: User = {
      id: u.user_id,
      username: u.username || u.display_name,
      display_name: u.display_name,
      role: u.user_role as User['role'],
    };

    setUser(newUser);
    setLocationName(u.location_name);
    localStorage.setItem(PWA_TOKEN_KEY, u.session_token);
    localStorage.setItem('pwa_user', JSON.stringify(newUser));
    localStorage.setItem('pwa_location_name', u.location_name);
  }

  async function loginSuperadmin(email: string, password: string) {
    localStorage.removeItem(PWA_TOKEN_KEY);
    localStorage.removeItem(OWNER_SESSION_KEY);
    const { data, error } = await supabase.rpc('pos_superadmin_login', {
      p_login: email.trim().toLowerCase(),
      p_password: password,
    });
    if (error) throw error;
    const session = Array.isArray(data) ? data[0] : data;
    if (!session?.session_token || !session?.location_id || !session?.user_id) {
      throw new Error('No se pudo iniciar la sesión global.');
    }

    const owner: User = {
      id: session.user_id,
      username: session.username || email.trim().toLowerCase(),
      display_name: session.display_name || 'Propietario',
      role: 'OWNER',
    };
    setUser(owner);
    setOwnerInspection(false);
    setLocationId(session.location_id);
    setLocationName(session.business_name || session.location_name || 'Administración del negocio');
    localStorage.setItem(PWA_TOKEN_KEY, session.session_token);
    localStorage.setItem('pwa_user', JSON.stringify(owner));
    localStorage.setItem('pwa_location_id', session.location_id);
    localStorage.setItem('pwa_location_name', session.business_name || session.location_name || 'Administración del negocio');
  }

  async function enterBranch(targetLocationId: string) {
    if (user?.role !== 'OWNER' || !locationId) throw new Error('Inicia sesión como propietario para abrir una sucursal.');
    const { data, error } = await supabase.rpc('pos_superadmin_enter_location', {
      p_token: getOperatorToken(),
      p_current_location_id: locationId,
      p_target_location_id: targetLocationId,
    });
    if (error) throw error;
    const session = Array.isArray(data) ? data[0] : data;
    if (!session?.session_token || !session?.location_id) throw new Error('No se pudo abrir la sucursal.');

    localStorage.setItem(OWNER_SESSION_KEY, JSON.stringify({
      user, locationId, locationName, token: getOperatorToken(),
    }));
    const branchUser: User = { ...user, role: 'ADMIN' };
    setUser(branchUser);
    setOwnerInspection(true);
    localStorage.setItem('pwa_user', JSON.stringify(branchUser));

    setLocationId(session.location_id);
    setLocationName(session.location_name);
    localStorage.setItem(PWA_TOKEN_KEY, session.session_token);
    localStorage.setItem('pwa_location_id', session.location_id);
    localStorage.setItem('pwa_location_name', session.location_name);
  }

  function returnToBranches() {
    try {
      const saved = JSON.parse(localStorage.getItem(OWNER_SESSION_KEY) || 'null');
      if (!saved?.user || !saved?.locationId || !saved?.token) throw new Error('No existe una sesión de propietario para restaurar.');
      setUser(saved.user);
      setOwnerInspection(false);
      setLocationId(saved.locationId);
      setLocationName(saved.locationName || 'Administración del negocio');
      localStorage.setItem('pwa_user', JSON.stringify(saved.user));
      localStorage.setItem('pwa_location_id', saved.locationId);
      localStorage.setItem('pwa_location_name', saved.locationName || 'Administración del negocio');
      localStorage.setItem(PWA_TOKEN_KEY, saved.token);
      localStorage.removeItem(OWNER_SESSION_KEY);
    } catch (error) {
      console.error('Could not restore owner session:', error);
      logout();
      window.location.assign('/login');
    }
  }

  function logout() {
    setUser(null);
    setOwnerInspection(false);
    setLocationId(null);
    setLocationName(null);
    setLocationUsers([]);
    localStorage.removeItem('pwa_user');
    localStorage.removeItem('pwa_location_id');
    localStorage.removeItem('pwa_location_name');
    localStorage.removeItem(PWA_TOKEN_KEY);
    localStorage.removeItem(OWNER_SESSION_KEY);
    void supabase.auth.signOut();
  }

  const isAdmin = user?.role === 'ADMIN' || user?.role === 'OWNER';
  const isCocina = user?.role === 'COCINA' || user?.role === 'ASADOR';

  return (
    <AuthContext.Provider value={{
      user, locationId, locationName, locationUsers, ownerInspection,
      loading, login, loginSuperadmin, enterBranch, returnToBranches, logout, setLocation, isAdmin, isCocina,
    }}>
      {children}
    </AuthContext.Provider>
  );
}

